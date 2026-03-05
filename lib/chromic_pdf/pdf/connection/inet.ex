# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(WebSockex) do
  defmodule ChromicPDF.Connection.Inet do
    @moduledoc false

    use ChromicPDF.Connection
    alias ChromicPDF.Connection.ConnectionLostError

    defmodule Websocket do
      @moduledoc false

      use WebSockex

      @spec start_link(binary()) :: GenServer.on_start()
      def start_link(websocket_debugger_url) do
        require Logger
        Logger.info("Websocket.start_link: url=#{websocket_debugger_url} caller=#{inspect(self())}")
        parsed = URI.parse(websocket_debugger_url)
        Logger.info("Websocket.start_link: URI.parse => host=#{inspect(parsed.host)} port=#{inspect(parsed.port)} scheme=#{inspect(parsed.scheme)}")
        result = WebSockex.start_link(websocket_debugger_url, __MODULE__, %{parent_pid: self()})
        Logger.info("Websocket.start_link: result=#{inspect(result)}")
        result
      end

      @impl WebSockex
      def handle_frame({:text, msg}, %{parent_pid: parent_pid} = state) do
        send(parent_pid, {:frame, msg})

        {:ok, state}
      end

      @spec send_frame(pid(), binary()) :: :ok
      def send_frame(pid, msg) do
        :ok = WebSockex.send_frame(pid, {:text, msg})
      end
    end

    @impl ChromicPDF.Connection
    def handle_init(opts) do
      require Logger
      {host, port} = Keyword.fetch!(opts, :chrome_address)
      Logger.info("Connection.Inet.handle_init: host=#{inspect(host)} port=#{inspect(port)} self=#{inspect(self())}")

      ws_url = websocket_debugger_url({host, port})
      Logger.info("Connection.Inet.handle_init: ws_url=#{ws_url}")

      # Debug: test gen_tcp from this process
      tcp_res = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, packet: 0], 5000)
      Logger.info("Connection.Inet.handle_init: gen_tcp test=#{inspect(tcp_res)}")
      case tcp_res do
        {:ok, s} -> :gen_tcp.close(s)
        _ -> :ok
      end

      Logger.info("Connection.Inet.handle_init: calling Websocket.start_link...")
      ws_result = Websocket.start_link(ws_url)
      Logger.info("Connection.Inet.handle_init: Websocket.start_link=#{inspect(ws_result)}")

      {:ok, ws_pid} = ws_result
      {:ok, %{ws_pid: ws_pid}}
    end

    @impl ChromicPDF.Connection
    def handle_msg(msg, %{ws_pid: ws_pid}) do
      Websocket.send_frame(ws_pid, msg)
    end

    @impl GenServer
    def handle_info({:frame, msg}, state) do
      send_msg_to_channel(msg, state)

      {:noreply, state}
    end

    defp websocket_debugger_url({host, port}) do
      # Ensure inets app is started. Ignore error if it was already.
      :inets.start()

      url = String.to_charlist("http://#{host}:#{port}/json/version")
      headers = [{~c"accept", ~c"application/json"}, {~c"host", ~c"localhost"}]
      http_request_opts = [ssl: [verify: :verify_none]]

      case :httpc.request(:get, {url, headers}, http_request_opts, []) do
        {:ok, {_, _, body}} ->
          body
          |> Jason.decode!()
          |> Map.fetch!("webSocketDebuggerUrl")
          |> rewrite_websocket_url(host, port)

        {:error, {:failed_connect, _}} ->
          raise ConnectionLostError, "failed to connect to #{url}"
      end
    end

    defp rewrite_websocket_url(url, host, port) do
      uri = URI.parse(url)
      URI.to_string(%{uri | host: to_string(host), port: port})
    end
  end
end
