defmodule Benchmark.ClientManager do
  use GenServer
  require Logger

  alias Benchmark.Stats.Histogram

  def start_client(%Grpc.Testing.ClientConfig{} = config) do
    {:ok, pid} = GenServer.start_link(__MODULE__, config)
    %{pid: pid}
  end

  def init(config) do
    # get security
    _payload_type = Benchmark.Manager.payload_type(config.payload_config)

    channels =
      0..(config.client_channels - 1)
      |> Enum.zip(config.server_targets)
      |> Enum.map(fn {_, server} -> new_client(server) end)

    payload = client_payload(config)
    rpcs_per_conn = config.outstanding_rpcs_per_channel

    hs_opts = histogram_opts(config.histogram_params)

    histograms =
      Enum.reduce(channels, {%{}, 0}, fn ch, {hs, i} ->
        Enum.reduce(0..(rpcs_per_conn - 1), hs, fn j, hs ->
          idx = i * rpcs_per_conn + j
          args = {self(), idx}
          {:ok, _pid} = GenServer.start_link(Benchmark.ClientWorker, {ch, payload, args})
          histogram = Histogram.new(hs_opts)
          Map.put(hs, idx, histogram)
        end)
      end)

    {:ok, %{histograms: histograms}}
  end

  def handle_call({:get_stats, reset}, _from, s) do
    # IO.inspect(s, limit: :infinity)
    {:reply, nil, s}
  end

  def handle_cast({:track_rpc, no, dur}, %{histograms: hs}) do
    new_his = Histogram.add(hs[no], dur)
    {:noreply, %{histograms: Map.put(hs, no, new_his)}}
  end

  def get_stats(%{pid: pid}, reset) do
    GenServer.call(pid, {:get_stats, reset})
  end

  defp new_client(addr) do
    {:ok, ch} = GRPC.Stub.connect(addr)
    ch
  end

  defp client_payload(%{rpc_type: rpc_type} = config) do
    if elem(config.load_params.load, 0) != :closed_loop,
      do:
        raise(
          GRPC.RPCError,
          status: :unimplemented,
          message: "load #{inspect(config.load_params.load)} not support"
        )

    payload =
      case config.payload_config.payload do
        {:simple_params, payload} ->
          %{req_size: payload.req_size, resp_size: payload.resp_size, type: :protobuf}

        _ ->
          raise(GRPC.RPCError, status: :unimplemented)
      end

    rpc_type = Grpc.Testing.RpcType.key(rpc_type)

    if rpc_type != :UNARY,
      do:
        raise(
          GRPC.RPCError,
          status: :unimplemented,
          message: "rpc_type #{inspect(rpc_type)} not support"
        )

    Map.put(payload, :rpc_type, rpc_type)
  end

  defp histogram_opts(hs_params) do
    Logger.debug(inspect(hs_params))

    %Benchmark.Stats.HistogramOpts{
      num_buckets:
        trunc(:math.log(hs_params.max_possible) / :math.log(1 + hs_params.resolution)) + 1,
      growth_factor: hs_params.resolution,
      base_bucket_size: 1 + hs_params.resolution,
      min_value: 0
    }
  end
end