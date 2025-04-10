# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    AbstractWorkerPool

Supertype for worker pools such as [`WorkerPool`](@ref) and [`CachingPool`](@ref).
An `AbstractWorkerPool` should implement:
  - [`push!`](@ref) - add a new worker to the overall pool (available + busy)
  - [`put!`](@ref) - put back a worker to the available pool
  - [`take!`](@ref) - take a worker from the available pool (to be used for remote function execution)
  - [`wait`](@ref) - block until a worker is available
  - [`length`](@ref) - number of workers available in the overall pool
  - [`isready`](@ref) - return false if a `take!` on the pool would block, else true

The default implementations of the above (on a `AbstractWorkerPool`) require fields
  - `channel::Channel{Int}`
  - `workers::Set{Int}`
where `channel` contains free worker pids and `workers` is the set of all workers associated with this pool.
"""
abstract type AbstractWorkerPool end

mutable struct WorkerPool <: AbstractWorkerPool
    channel::Channel{Int}
    workers::Set{Int}
    ref::RemoteChannel

    WorkerPool(c::Channel, ref::RemoteChannel) = new(c, Set{Int}(), ref)
end

function WorkerPool(; role= :default)
    wp = WorkerPool(Channel{Int}(typemax(Int)), RemoteChannel(role = role))
    put!(wp.ref, WeakRef(wp), role=role)
    wp
end

"""
    WorkerPool(workers::Union{Vector{Int},AbstractRange{Int}})

Create a `WorkerPool` from a vector or range of worker ids.

# Examples
```julia-repl
\$ julia -p 3

julia> WorkerPool([2, 3])
WorkerPool(Channel{Int64}(sz_max:9223372036854775807,sz_curr:2), Set([2, 3]), RemoteChannel{Channel{Any}}(1, 1, 6))

julia> WorkerPool(2:4)
WorkerPool(Channel{Int64}(sz_max:9223372036854775807,sz_curr:2), Set([4, 2, 3]), RemoteChannel{Channel{Any}}(1, 1, 7))
```
"""
function WorkerPool(workers::Union{Vector{Int},AbstractRange{Int}}; role= :default)
    pool = WorkerPool(role = role)
    foreach(w->push!(pool, w), workers)
    return pool
end

# On workers where this pool has been serialized to, instantiate with a dummy local channel.
WorkerPool(ref::RemoteChannel) = WorkerPool(Channel{Int}(1), ref)

function serialize(S::AbstractSerializer, pool::WorkerPool; role = :default)
    # Allow accessing a worker pool from other processors. When serialized,
    # initialize the `ref` to point to self and only send the ref.
    # Other workers will forward all put!, take!, calls to the process owning
    # the ref (and hence the pool).
    Serialization.serialize_type(S, typeof(pool))
    serialize(S, pool.ref; role = role)
end

deserialize(S::AbstractSerializer, t::Type{T}) where {T<:WorkerPool} = T(deserialize(S))

wp_local_push!(pool::AbstractWorkerPool, w::Int; role= :default) = (push!(pool.workers, w); put!(pool.channel, w); pool)
wp_local_length(pool::AbstractWorkerPool; role= :default) = length(pool.workers)
wp_local_isready(pool::AbstractWorkerPool; role= :default) = isready(pool.channel)  # pool.channel::Channel{Int}

function wp_local_put!(pool::AbstractWorkerPool, w::Int; role= :default)
    # In case of default_worker_pool, the master is implicitly considered a worker, i.e.,
    # it is not present in pool.workers.
    # Confirm the that the worker is part of a pool before making it available.
    w in pool.workers && put!(pool.channel, w)
    w
end

function wp_local_workers(pool::AbstractWorkerPool; role= :default)
    if length(pool) == 0 && pool === default_worker_pool(role=role)
        return [1]
    else
        return collect(pool.workers)
    end
end

function wp_local_nworkers(pool::AbstractWorkerPool; role= :default)
    if length(pool) == 0 && pool === default_worker_pool(role=role)
        return 1
    else
        return length(pool.workers)
    end
end

function wp_local_take!(pool::AbstractWorkerPool; role= :default)
    # Find an active worker
    worker = 0
    while true
        if length(pool) == 0
            if pool === default_worker_pool(role=role)
                # No workers, the master process is used as a worker
                worker = 1
                break
            else
                throw(ErrorException("No active worker available in pool"))
            end
        end

        worker = take!(pool.channel)
        if id_in_procs(worker)
            break
        else
            delete!(pool.workers, worker) # Remove invalid worker from pool
        end
    end
    return worker
end

function wp_local_wait(pool::AbstractWorkerPool)
    wait(pool.channel)
    return nothing
end

function remotecall_pool(rc_f, f, pool::AbstractWorkerPool, args...; role= :default, kwargs...)
    worker = take!(pool; role=role)
    try
        rc_f(f, worker, role=role, args...; kwargs...)
    finally
        put!(pool, worker; role = role)
    end
end

# Specialization for remotecall. We have to wait for the Future it returns
# before putting the worker back in the pool.
function remotecall_pool(rc_f::typeof(remotecall), f, pool::AbstractWorkerPool, args...; kwargs...)
    worker = take!(pool)
    local x
    try
        x = rc_f(f, worker, args...; kwargs...)
    catch
        put!(pool, worker)
        rethrow()
    end
    t = Threads.@spawn Threads.threadpool() try
        wait(x)
    catch # just wait, ignore errors here
    finally
        put!(pool, worker)
    end
    errormonitor(t)
    return x
end

# Check if pool is local or remote and forward calls if required.
# NOTE: remotecall_fetch does it automatically, but this will be more efficient as
# it avoids the overhead associated with a local remotecall.

for (func, rt) = ((:length, Int), (:isready, Bool), (:workers, Vector{Int}), (:nworkers, Int), (:take!, Int), (:wait, Nothing))
    func_local = Symbol(string("wp_local_", func))
    @eval begin
        function ($func)(pool::WorkerPool; role= :default)
            if pool.ref.where != myid(role = role)
                return remotecall_fetch((ref, role)->(($func_local)(fetch(ref; role=role).value; role = role)), pool.ref.where, pool.ref, pool.ref.where == 1 ? :master : :worker; role = role)::$rt
            else
                return ($func_local)(pool; role = role)
            end
        end

        # default impl
        ($func)(pool::AbstractWorkerPool; role= :default) = ($func_local)(pool; role = role)
    end
end

for func = (:push!, :put!)
    func_local = Symbol(string("wp_local_", func))
    @eval begin
        function ($func)(pool::WorkerPool, w::Int; role= :default)
            if pool.ref.where != myid(role = role)
                return remotecall_fetch((ref, w, role)->(($func_local)(fetch(ref; role = role).value, w; role = role)), pool.ref.where, pool.ref, w, pool.ref.where == 1 ? :master : :worker; role = role)
            else
                return ($func_local)(pool, w; role = role)
            end
        end

        # default impl
        ($func)(pool::AbstractWorkerPool, w::Int; role= :default) = ($func_local)(pool, w; role = role)
    end
end


"""
    remotecall(f, pool::AbstractWorkerPool, args...; kwargs...) -> Future

[`WorkerPool`](@ref) variant of `remotecall(f, pid, ....)`. Wait for and take a free worker from `pool` and perform a `remotecall` on it.

# Examples
```julia-repl
\$ julia -p 3

julia> wp = WorkerPool([2, 3]);

julia> A = rand(3000);

julia> f = remotecall(maximum, wp, A)
Future(2, 1, 6, nothing)
```
In this example, the task ran on pid 2, called from pid 1.
"""
#remotecall(f, pool::AbstractWorkerPool, args...; role= :default, kwargs...) = remotecall_pool((f, pool) -> remotecall(f, pool, role=role, args...; kwargs...); role=role)
remotecall(f, pool::AbstractWorkerPool, args...; kwargs...) = remotecall_pool(remotecall, f, pool, args...; kwargs...)


"""
    remotecall_wait(f, pool::AbstractWorkerPool, args...; kwargs...) -> Future

[`WorkerPool`](@ref) variant of `remotecall_wait(f, pid, ....)`. Wait for and take a free worker from `pool` and
perform a `remotecall_wait` on it.

# Examples
```julia-repl
\$ julia -p 3

julia> wp = WorkerPool([2, 3]);

julia> A = rand(3000);

julia> f = remotecall_wait(maximum, wp, A)
Future(3, 1, 9, nothing)

julia> fetch(f)
0.9995177101692958
```
"""
#remotecall_wait(f, pool::AbstractWorkerPool, args...; role= :default, kwargs...) = remotecall_pool((f,pool) -> remotecall_wait(f, pool, role = role, args...; kwargs...); role=role)  # TO CHECK (dúvida com "role = role")
remotecall_wait(f, pool::AbstractWorkerPool, args...; kwargs...) = remotecall_pool(remotecall_wait, f, pool, args...; kwargs...)


"""
    remotecall_fetch(f, pool::AbstractWorkerPool, args...; kwargs...) -> result

[`WorkerPool`](@ref) variant of `remotecall_fetch(f, pid, ....)`. Waits for and takes a free worker from `pool` and
performs a `remotecall_fetch` on it.

# Examples
```julia-repl
\$ julia -p 3

julia> wp = WorkerPool([2, 3]);

julia> A = rand(3000);

julia> remotecall_fetch(maximum, wp, A)
0.9995177101692958
```
"""
#remotecall_fetch(f, pool::AbstractWorkerPool, args...; role= :default, kwargs...) = remotecall_pool((f,pool)->remotecall_fetch(f, pool, role = role, args...; kwargs...), f, pool; role = role) # TO CHECK (dúvida com o primeiro "role = role")
remotecall_fetch(f, pool::AbstractWorkerPool, args...; kwargs...) = remotecall_pool(remotecall_fetch, f, pool, args...; kwargs...)
#remotecall_fetch(f, pool::AbstractWorkerPool, args...; role= :default, kwargs...) = remotecall_pool((f,pool)->remotecall_fetch((p, args...) -> f(p, args...), pool, args...; role = role, kwargs...), f, pool; role = role) # TO CHECK (dúvida com o primeiro "role = role")

"""
    remote_do(f, pool::AbstractWorkerPool, args...; kwargs...) -> nothing

[`WorkerPool`](@ref) variant of `remote_do(f, pid, ....)`. Wait for and take a free worker from `pool` and
perform a `remote_do` on it.

Note that it's not possible to wait for the result of a `remote_do()` to finish
so the worker will immediately be put back in the pool (i.e. potentially causing
oversubscription).
"""
#remote_do(f, pool::AbstractWorkerPool, args...; role= :default, kwargs...) = remotecall_pool((f,pool) -> remote_do(f, pool, role = role, args...; kwargs...); role = role)
remote_do(f, pool::AbstractWorkerPool, args...; kwargs...) = remotecall_pool(remote_do, f, pool, args...; kwargs...)

const _default_worker_pool = Ref{Union{AbstractWorkerPool, Nothing}}(nothing)

"""
    default_worker_pool()

[`AbstractWorkerPool`](@ref) containing idle [`workers`](@ref) - used by `remote(f)` and [`pmap`](@ref)
(by default). Unless one is explicitly set via `default_worker_pool!(pool)`, the default worker pool is
initialized to a [`WorkerPool`](@ref).

# Examples
```julia-repl
\$ julia -p 3

julia> default_worker_pool()
WorkerPool(Channel{Int64}(sz_max:9223372036854775807,sz_curr:3), Set([4, 2, 3]), RemoteChannel{Channel{Any}}(1, 1, 4))
```
"""
function default_worker_pool(;role=:default)
    # On workers retrieve the default worker pool from the master when accessed
    # for the first time
    if _default_worker_pool[] === nothing
        if myid(role=role) == 1
            _default_worker_pool[] = WorkerPool(role = role)
        else
            _default_worker_pool[] = remotecall_fetch(role->default_worker_pool(role = role), 1, :master; role=role)
        end
    end
    return _default_worker_pool[]
end

"""
    default_worker_pool!(pool::AbstractWorkerPool)

Set a [`AbstractWorkerPool`](@ref) to be used by `remote(f)` and [`pmap`](@ref) (by default).
"""
function default_worker_pool!(pool::AbstractWorkerPool)
    _default_worker_pool[] = pool
end

"""
    remote([p::AbstractWorkerPool], f) -> Function

Return an anonymous function that executes function `f` on an available worker
(drawn from [`WorkerPool`](@ref) `p` if provided) using [`remotecall_fetch`](@ref).
"""
remote(f; role= :default) = (args...; kwargs...)->remotecall_fetch(f, default_worker_pool(role=role), args...; role=role, kwargs...)
remote(p::AbstractWorkerPool, f; role= :default) = (args...; kwargs...)->remotecall_fetch(f, p, args...; role=role, kwargs...)

mutable struct CachingPool <: AbstractWorkerPool
    channel::Channel{Int}
    workers::Set{Int}

    # Mapping between a tuple (worker_id, f) and a RemoteChannel
    map_obj2ref::IdDict{Tuple{Int, Function}, RemoteChannel}

    function CachingPool()
        wp = new(Channel{Int}(typemax(Int)), Set{Int}(), IdDict{Tuple{Int, Function}, RemoteChannel}())
        finalizer(clear!, wp)
        wp
    end
end

serialize(s::AbstractSerializer, cp::CachingPool) = throw(ErrorException("CachingPool objects are not serializable."))

"""
    CachingPool(workers::Vector{Int})

An implementation of an `AbstractWorkerPool`.
[`remote`](@ref), [`remotecall_fetch`](@ref),
[`pmap`](@ref) (and other remote calls which execute functions remotely)
benefit from caching the serialized/deserialized functions on the worker nodes,
especially closures (which may capture large amounts of data).

The remote cache is maintained for the lifetime of the returned `CachingPool` object.
To clear the cache earlier, use `clear!(pool)`.

For global variables, only the bindings are captured in a closure, not the data.
`let` blocks can be used to capture global data.

# Examples
```julia
const foo = rand(10^8);
wp = CachingPool(workers())
let foo = foo
    pmap(i -> sum(foo) + i, wp, 1:100);
end
```

The above would transfer `foo` only once to each worker.

"""
function CachingPool(workers::Vector{Int})
    pool = CachingPool()
    for w in workers
        push!(pool, w)
    end
    return pool
end

"""
    clear!(pool::CachingPool) -> pool

Removes all cached functions from all participating workers.
"""
function clear!(pool::CachingPool)
    for (_,rr) in pool.map_obj2ref
        finalize(rr)
    end
    empty!(pool.map_obj2ref)
    pool
end

exec_from_cache(rr::RemoteChannel, args...; role= :default, kwargs...) = fetch(rr; role = role)(args...; kwargs...)
function exec_from_cache(f_ref::Tuple{Function, RemoteChannel}, args...; role= :default, kwargs...)
    put!(f_ref[2], f_ref[1])        # Cache locally
    f_ref[1](args...; kwargs...)
end

function remotecall_pool(rc_f, f, pool::CachingPool, args...; role= :default, kwargs...)
    worker = take!(pool; role=role)
    f_ref = get(pool.map_obj2ref, (worker, f), (f, RemoteChannel(worker; role=role)))
    isa(f_ref, Tuple) && (pool.map_obj2ref[(worker, f)] = f_ref[2])   # Add to tracker

    try
        rc_f(exec_from_cache, worker, f_ref, args...; role=role, kwargs...)
    finally
        put!(pool, worker; role=role)
    end
end


# Specialization for remotecall. We have to wait for the Future it returns
# before putting the worker back in the pool.
function remotecall_pool(rc_f::typeof(remotecall), f, pool::CachingPool, args...; role= :default, kwargs...)
    worker = take!(pool; role=role)
    f_ref = get(pool.map_obj2ref, (worker, f), (f, RemoteChannel(worker; role=role)))
    isa(f_ref, Tuple) && (pool.map_obj2ref[(worker, f)] = f_ref[2])   # Add to tracker
    local x
    try
        x = rc_f(exec_from_cache, worker, f_ref, args...; role=role, kwargs...)
    catch
        put!(pool, worker; role=role)
        rethrow()
    end
    t = Threads.@spawn Threads.threadpool() try
        wait(x)
    catch # just wait, ignore errors here
    finally
        put!(pool, worker; role=role)
    end
    errormonitor(t)
    return x
end