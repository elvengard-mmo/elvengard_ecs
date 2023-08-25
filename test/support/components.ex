defmodule ElvenGard.ECS.Components do
  defmodule PlayerComponent do
    use ElvenGard.ECS.Component, state: [name: "Player"]
  end

  defmodule PositionComponent do
    use ElvenGard.ECS.Component, state: [map_id: 1, pos_x: 0, pos_y: 0]
  end

  defmodule BuffComponent do
    use ElvenGard.ECS.Component, state: [buff_id: nil]
  end
end
