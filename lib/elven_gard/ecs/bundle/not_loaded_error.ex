defmodule ElvenGard.ECS.Bundle.NotLoadedError do
  @moduledoc """
  Raised when a bundle getter reads a component that was not selected or preloaded.
  """

  defexception [:bundle, :component]

  ## Exception callbacks

  @impl true
  def message(exception) do
    %__MODULE__{bundle: bundle, component: component} = exception

    "#{inspect(component)} is not loaded in #{inspect(bundle)}; " <>
      "select it in the query or preload it before reading"
  end
end
