defmodule ElvenGard.ECS.Components do
  @moduledoc false

  defmodule PlayerComponent do
    @moduledoc false

    use ElvenGard.ECS.Component, state: [name: "Player"]
  end

  defmodule PositionComponent do
    @moduledoc false

    use ElvenGard.ECS.Component, state: [map_id: 1, pos_x: 0, pos_y: 0]
  end

  defmodule BuffComponent do
    @moduledoc false

    use ElvenGard.ECS.Component, state: [buff_id: nil]
  end
end
