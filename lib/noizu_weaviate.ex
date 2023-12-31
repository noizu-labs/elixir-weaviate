defmodule Noizu.Weaviate do
  @moduledoc """
  Noizu.Weaviate is a library providing a simple wrapper around Weaviate's API calls.
  It handles various API features such as meta information, batch operations, backups,
  schema operations, nodes information, data objects, and classification.

  ## Configuration

  To configure the library, you need to set the Weaviate API key in your application's configuration:

      config :noizu_weaviate,
        weaviate_api_key: "your_api_key_here"
  """

  require Logger
  # -------------------------------
  # Global Types
  # -------------------------------
  @type error_tuple :: {:error, details :: term}

  # option constraints
  @type consistency_level_option() :: String.t()

  # common types
  @type api_response() :: {:ok, map()} | {:error, any()}

  # Common Type
  @type options() :: map()

  @weaviate_base Application.compile_env(:noizu_weaviate, :endpoint, "http://api.weaviate.com/")

  require Finch

  def weaviate_base(), do: @weaviate_base
  def api_base(), do: @weaviate_base

  # -------------------------------
  #
  # -------------------------------
  def generic_stream_provider(callback) do
    fn event, payload ->
      case event do
        {:status, code} ->
          %{payload | status: code}

        {:headers, headers} ->
          %{payload | headers: headers}

        {:data, data} ->
          n =
            String.split(data, "\n\ndata:")
            |> Enum.map(fn data ->
              case Jason.decode(data, keys: :atoms) do
                {:ok, json} ->
                  case json do
                    %{:choices => [%{:delta => %{:content => c}, :finish_reason => _} | _]} -> c
                    _ -> nil
                  end

                _ ->
                  nil
              end
            end)
            |> Enum.filter(& &1)
            |> Enum.join("")

          payload = %{payload | message: payload.message <> n}
          # Call the provided callback function with the payload
          callback.(payload)

        _ ->
          payload
      end
    end
  end

  # -------------------------------
  #
  # -------------------------------
  @doc """
  A helper function to make API calls to the OpenAI API. This function handles both non-stream and stream API calls.

  ## Parameters

  - type: The HTTP request method (e.g., :get, :post, :put, :patch, :delete)
  - url: The full URL for the API endpoint
  - body: The request body in map format
  - model: The model to be used for the response processing
  - options
    - stream: A boolean value to indicate whether the request should be processed as a stream or not (default: false)
    - raw: return raw response
    - response_log_callback: function(finch) callback for request log.
    - response_log_callback: function(finch, start_ms) callback for response log.

  ## Returns

  Returns a tuple {:ok, response} on successful API call, where response is the decoded JSON response in map format.
  Returns {:error, term} on failure, where term contains error details.
  """
  def api_call(type, url, body, model, options \\ nil) do
    stream = options[:stream] || false
    raw = options[:raw] || false

    if stream do
      with {:ok, body} <- (body && Jason.encode(body)) || {:ok, nil},
           {:ok, r = %{status: 200, message: _}} <- api_call_stream(type, url, body, options) do
        {:ok, r}
        # apply(model, :from_json, [json])
      else
        error ->
          Logger.warn("STREAM API ERROR: \n #{inspect(error)}")
          error
      end
    else
      with {:ok, body} <- (body && Jason.encode(body)) || {:ok, nil},
           {:ok, %Finch.Response{status: 200, body: body}} <-
             api_call_fetch(type, url, body, options),
           {:ok, json} <- (!raw && ( (String.length(body) > 0) && Jason.decode(body, keys: :atoms) || {:ok, nil} )) || {:ok, body} do
        cond do
          model in [nil, :json] -> {:ok, json}
          raw -> {:ok, apply(model, :from_binary, [json])}
          :else -> {:ok, apply(model, :from_json, [json])}
        end
      else
        error ->
          Logger.warn("API ERROR: \n #{inspect(error)}")
          error
      end
    end
  end

  # -------------------------------
  #
  # -------------------------------
  def headers() do
    [
      {"Content-Type", "application/json"}
    ]
    |> then(fn headers ->
      headers
    end)
  end

  # -------------------------------
  #
  # -------------------------------
  def put_field(body, field, options, default \\ nil)

  def put_field(body, :stream, options, default) do
    flag = (options[:stream] && true) || default
    Map.put(body, :stream, flag)
  end

  def put_field(body, {field_alias, field}, options, default) do
    if v = options[field_alias] || options[field] || default do
      Map.put(body, field, v)
    else
      body
    end
  end

  def put_field(body, field, options, default) do
    if v = options[field] || default do
      Map.put(body, field, v)
    else
      body
    end
  end

  # -------------------------------
  #
  # -------------------------------
  defp api_call_fetch(type, url, body, options) do
    ts = :os.system_time(:millisecond)

    request =
      Finch.build(type, url, headers(), body)
      |> tap(fn finch ->
        case request_log_callback = options[:request_log_callback] do
          nil -> :nop
          v when is_function(v, 1) -> v.(finch)
          {m, f} -> apply(m, f, [finch])
          _ -> :nop
        end
      end)

    # |> IO.inspect(label: "API_CALL_FETCH", limit: :infinity, printable_limit: :infinity, pretty: true)
    request
    |> Finch.request(Noizu.Weaviate.Finch,
      pool_timeout: 600_000,
      receive_timeout: 600_000,
      request_timeout: 600_000
    )
    |> tap(fn finch ->
      case response_log_callback = options[:response_log_callback] do
        nil -> :nop
        v when is_function(v, 3) -> v.(finch, request, ts)
        {m, f} -> apply(m, f, [finch, request, ts])
        _ -> :nop
      end
    end)
  end

  # -------------------------------
  #
  # -------------------------------
  defp api_call_stream(type, url, body, options) do
    callback = options[:stream]
    raw = options[:raw]
    ts = :os.system_time(:millisecond)

    request =
      Finch.build(type, url, headers(), body)
      |> tap(fn finch ->
        case request_log_callback = options[:request_log_callback] do
          nil -> :nop
          v when is_function(v, 1) -> v.(finch)
          {m, f} -> apply(m, f, [finch])
          _ -> :nop
        end
      end)

    request
    |> Finch.stream(Noizu.Weaviate.Finch, %{status: nil, raw: raw, message: ""}, callback,
      timeout: 600_000,
      receive_timeout: 600_000
    )
    |> tap(fn finch ->
      case response_log_callback = options[:response_log_callback] do
        nil -> :nop
        v when is_function(v, 3) -> v.(finch, request, ts)
        {m, f} -> apply(m, f, [finch, request, ts])
        _ -> :nop
      end
    end)
  end
end
