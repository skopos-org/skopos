defmodule Skopos.Providers.TargetClassificationTest do
  use ExUnit.Case, async: true

  alias Skopos.Providers.Target

  defmodule Classifier do
    def classify_request(_state, %{parameters: %{"method" => "GET"}}),
      do: {:ok, :observation}

    def classify_request(_state, %{parameters: %{"method" => "POST"}}),
      do: {:ok, :effect}

    def classify_request(_state, _request),
      do: {:error, :failed, "Unsupported exact request"}
  end

  defmodule InvalidClassifier do
    def classify_request(_state, _request), do: {:ok, :observation, :effect}
  end

  defmodule MissingClassifier do
  end

  test "the same bounded Method request is classified from exact content" do
    request = request(%{"method" => "GET"})

    assert {:ok, %Target.RequestClassification{kind: :observation}} =
             Target.classify_request(Classifier, %{}, request)

    assert {:ok, %Target.RequestClassification{kind: :effect}} =
             Target.classify_request(Classifier, %{}, %{
               request
               | parameters: %{"method" => "POST"}
             })
  end

  test "oversized content and invalid callbacks fail closed" do
    request = request(%{"method" => "GET"})
    oversized = %{request | parameters: %{"body" => String.duplicate("x", 65_537)}}

    assert {:error, :failed, "Target Method request is invalid"} =
             Target.classify_request(Classifier, %{}, oversized)

    assert {:error, :failed, "Target classifier returned an invalid result"} =
             Target.classify_request(InvalidClassifier, %{}, request)

    assert {:error, :failed, "Target classifier is unavailable"} =
             Target.classify_request(MissingClassifier, %{}, request)
  end

  defp request(parameters) do
    %Target.MethodRequest{
      provider_revision: 1,
      connection: %Target.Connection{endpoint: "https://device.example.test"},
      capability: "request.http.observe",
      operation: "request.observe",
      selectors: %{},
      parameters: parameters
    }
  end
end
