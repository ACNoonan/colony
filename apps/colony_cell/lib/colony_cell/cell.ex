defmodule ColonyCell.Cell do
  use GenServer

  alias ColonyCore.Event

  @moduledoc """
  Minimal replay-friendly cell process.

  Today this is a GenServer so the repo stays dependency-light. The interface is
  intentionally shaped so we can later swap the internals to Jido processes plus
  Kafka consumers without rewriting the whole demo surface.
  """

  def start_link(opts) do
    cell_id = Keyword.fetch!(opts, :cell_id)
    GenServer.start_link(__MODULE__, opts, name: ColonyCell.via(cell_id))
  end

  @impl true
  def init(opts) do
    state = %{
      cell_id: Keyword.fetch!(opts, :cell_id),
      handled_events: MapSet.new(),
      last_sequence: 0,
      projections: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, %Event{} = event}, _from, state) do
    if MapSet.member?(state.handled_events, event.id) do
      {:reply, {:ok, :duplicate}, state}
    else
      next_state =
        state
        |> record_event(event)
        |> project_event(event)

      {:reply, {:ok, :accepted}, next_state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      cell_id: state.cell_id,
      last_sequence: state.last_sequence,
      handled_events: MapSet.size(state.handled_events),
      projections: state.projections
    }

    {:reply, snapshot, state}
  end

  defp record_event(state, %Event{} = event) do
    %{state | handled_events: MapSet.put(state.handled_events, event.id)}
  end

  defp project_event(state, %Event{subject: subject, sequence: sequence, data: data}) do
    projections = Map.update(state.projections, subject, [data], &[data | &1])

    %{state | projections: projections, last_sequence: max(sequence || 0, state.last_sequence)}
  end
end
