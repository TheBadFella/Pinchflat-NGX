defmodule Pinchflat.Sources.SourceImport do
  @moduledoc """
  Parses bounded URL lists and Google Takeout subscription CSVs without provider or database calls.
  """

  @header ["channel id", "channel url", "channel title"]
  @channel_id ~r/\AUC[A-Za-z0-9_-]{22}\z/
  @limit_error "Choose a file with 1 to 100 entries. Split larger exports into smaller files."

  @doc """
  Parses a UTF-8 .txt or .csv source file into a preview, including rejected CSV records.

  Returns {:ok, map()} | {:error, binary()}
  """
  def parse(contents, filename) when is_binary(contents) and is_binary(filename) do
    if String.valid?(contents) do
      case filename |> Path.extname() |> String.downcase() do
        ".txt" -> parse_text(contents)
        ".csv" -> parse_csv(contents)
        _ -> {:error, "Choose a .txt URL list or a Google Takeout subscriptions.csv file."}
      end
    else
      {:error, "The file must use UTF-8 text encoding."}
    end
  end

  def parse(_contents, _filename), do: {:error, "Choose a .txt or .csv source file."}

  defp preview(download_media) do
    %{urls: [], titles: %{}, channel_ids: %{}, duplicates: 0, row_errors: [], download_media: download_media}
  end

  defp parse_text(contents) do
    urls = contents |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if length(urls) in 1..100 do
      unique = Enum.uniq(urls)
      {:ok, %{preview(true) | urls: unique, duplicates: length(urls) - length(unique)}}
    else
      {:error, "Choose a text file with 1 to 100 URLs (100 KB maximum)."}
    end
  end

  defp parse_csv(contents) do
    records =
      contents
      |> String.trim_leading("\uFEFF")
      |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
      |> Enum.reject(fn row -> Enum.all?(row, &(String.trim(&1) == "")) end)

    case records do
      [header | rows] ->
        cond do
          Enum.map(header, &String.downcase(String.trim(&1))) != @header ->
            {:error, "Use a Google Takeout CSV with Channel Id, Channel Url, Channel Title columns, in that order."}

          length(rows) not in 1..100 ->
            {:error, @limit_error}

          true ->
            result = rows |> Enum.with_index(2) |> Enum.reduce(preview(false), &add_csv_row/2)
            {:ok, %{result | urls: Enum.reverse(result.urls), row_errors: Enum.reverse(result.row_errors)}}
        end

      _ ->
        {:error, @limit_error}
    end
  rescue
    NimbleCSV.ParseError -> {:error, "The CSV has malformed quoting or separators. Upload the original Takeout CSV."}
  end

  defp add_csv_row({fields, row}, result) do
    case csv_channel(fields) do
      {:ok, id, url, title} ->
        if Map.has_key?(result.channel_ids, url) do
          %{result | duplicates: result.duplicates + 1}
        else
          %{
            result
            | urls: [url | result.urls],
              titles: Map.put(result.titles, url, title),
              channel_ids: Map.put(result.channel_ids, url, id)
          }
        end

      {:error, message} ->
        %{result | row_errors: [%{row: row, message: message} | result.row_errors]}
    end
  end

  defp csv_channel([id, url, title]) do
    id = String.trim(id)

    cond do
      !Regex.match?(@channel_id, id) ->
        {:error, "Invalid YouTube channel ID."}

      !matching_channel_url?(String.trim(url), id) ->
        {:error, "The channel URL must be a YouTube channel URL matching its Channel Id."}

      true ->
        {:ok, id, "https://www.youtube.com/channel/#{id}", title |> String.trim() |> :binary.copy()}
    end
  end

  defp csv_channel(_fields), do: {:error, "Expected exactly three CSV columns."}

  defp matching_channel_url?(url, id) do
    with {:ok, %URI{scheme: scheme, host: host, path: path, userinfo: nil, port: port}} <- URI.new(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and String.downcase(host) in ["youtube.com", "www.youtube.com"],
         true <- port == URI.default_port(scheme) do
      String.trim_trailing(path || "", "/") == "/channel/#{id}"
    else
      _ -> false
    end
  end
end
