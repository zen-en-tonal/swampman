defmodule Swampman.Application do
  @moduledoc false

  use Application

  def start(_start_type, _start_args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Swampman.DynamicSup}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
