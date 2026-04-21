defmodule Mix.Tasks.Colony.Tail do
  @shortdoc "Stream the colony runtime log (or any topic) to stdout"

  @moduledoc """
  Usage: mix colony.tail [options]

  Options:
    --topic <t>            Topic to tail (default: colony.runtime.log)
    --cell <name>          Only show events whose subject, partition_key,
                           or origin_subject equals <name>
    --role <role>          Only show events whose source (or origin_source
                           in runtime.log envelopes) has <role> as its
                           leading "<role>.<partition>" prefix
    --correlation <id>     Only show events in one correlation chain
    --since earliest|latest
                           Start offset (default: latest)
    --no-color             Disable ANSI color coding

  This is the colony analog of swarm-forge's swarmlog.sh + logger pane.
  It attaches to a one-off consumer group, so it does not interfere
  with any running consumer. Stop with Ctrl-C.
  """

  use Mix.Task

  alias ColonyCore.Event
  alias Mix.Tasks.Colony.Tail.Filters

  @default_topic "colony.runtime.log"
  @palette [31, 32, 33, 34, 35, 36, 91, 92, 93, 94, 95, 96]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          topic: :string,
          cell: :string,
          role: :string,
          correlation: :string,
          since: :string,
          no_color: :boolean
        ],
        aliases: [t: :topic, c: :cell, r: :role]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{inspect(invalid)}")
      exit({:shutdown, 1})
    end

    topic = Keyword.get(opts, :topic, @default_topic)
    color? = !Keyword.get(opts, :no_color, false)
    begin_offset = parse_since(Keyword.get(opts, :since, "latest"))
    filters = Filters.build(opts)

    Mix.shell().info(
      "tail: #{topic} (offset=#{begin_offset}, filters=#{Filters.format(filters)}) — Ctrl-C to stop"
    )

    handler = fn %Event{} = event ->
      if Filters.passes?(event, filters), do: print_event(event, color?)
      :ok
    end

    case ColonyKafka.subscribe(topic,
           handler: handler,
           group_id: "colony-tail-#{System.unique_integer([:positive])}",
           begin_offset: begin_offset
         ) do
      {:ok, _pid} ->
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.shell().error("subscribe failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_since("earliest"), do: :earliest
  defp parse_since("latest"), do: :latest

  defp parse_since(other) do
    Mix.shell().error("--since must be 'earliest' or 'latest' (got #{inspect(other)})")
    exit({:shutdown, 1})
  end

  defp print_event(%Event{type: "runtime.logged"} = event, color?) do
    ts = format_ts(event.recorded_at)
    source = get_in(event.data, ["origin_source"]) || event.source
    type = get_in(event.data, ["origin_type"]) || "?"
    subject = get_in(event.data, ["origin_subject"]) || event.subject
    corr = truncate(event.correlation_id, 8)

    Mix.shell().info(
      [
        ts,
        "  ",
        paint(source, color?),
        "  ",
        type,
        "  subject=",
        subject,
        "  corr=",
        corr
      ]
      |> IO.iodata_to_binary()
    )
  end

  defp print_event(%Event{} = event, color?) do
    ts = format_ts(event.recorded_at)
    corr = truncate(event.correlation_id, 8)
    action = if event.action_key, do: "  action=#{event.action_key}", else: ""

    Mix.shell().info(
      [
        ts,
        "  ",
        paint(event.source, color?),
        "  ",
        event.type,
        "  subject=",
        to_string(event.subject),
        "  corr=",
        corr,
        action
      ]
      |> IO.iodata_to_binary()
    )
  end

  defp format_ts(nil), do: "          "

  defp format_ts(%DateTime{} = dt) do
    dt
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 8)
  end

  defp truncate(nil, _), do: "-"
  defp truncate(str, n) when is_binary(str), do: String.slice(str, 0, n)

  defp paint(text, false), do: text

  defp paint(text, true) do
    code = Enum.at(@palette, rem(:erlang.phash2(text), length(@palette)))
    "\e[#{code}m" <> text <> "\e[0m"
  end
end
