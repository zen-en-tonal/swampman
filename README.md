# Swampman

Swampman is a lightweight worker pool manager for Elixir applications.

It allows you to manage a pool of worker processes, providing functionality to check out and check in workers, as well as dynamically resize the pool.

## Features

- Configurable pool size and overflow size.
- Automatic worker process management.
- Simple API for checking out and checking in workers.
- Transaction support for executing functions with a checked-out worker.
- Dynamic resizing of the worker pool.

## Installation

Add `swampman` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:swampman, "~> 0.0.1"}
  ]
end
```

## License

See [LICENSE](LICENSE) for details.
