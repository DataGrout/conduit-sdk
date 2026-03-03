defmodule DatagroutConduit.GuidedSessionTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.GuidedSession
  alias DatagroutConduit.Types

  describe "struct" do
    test "has expected fields" do
      session = %GuidedSession{
        client: self(),
        session_id: "sess-1",
        state: %Types.GuideState{
          session_id: "sess-1",
          status: "in_progress",
          options: [
            %Types.GuideOption{tool_name: "tool-a", description: "Tool A"},
            %Types.GuideOption{tool_name: "tool-b", description: "Tool B"}
          ]
        }
      }

      assert session.session_id == "sess-1"
      assert session.client == self()
    end
  end

  describe "options/1" do
    test "returns the current options list" do
      opts = [
        %Types.GuideOption{tool_name: "a", description: "A"},
        %Types.GuideOption{tool_name: "b", description: "B"}
      ]

      session = %GuidedSession{
        client: self(),
        session_id: "s1",
        state: %Types.GuideState{options: opts, status: "in_progress"}
      }

      assert GuidedSession.options(session) == opts
    end
  end

  describe "status/1" do
    test "returns the session status" do
      session = %GuidedSession{
        client: self(),
        session_id: "s1",
        state: %Types.GuideState{status: "in_progress"}
      }

      assert GuidedSession.status(session) == "in_progress"
    end
  end

  describe "complete/1" do
    test "returns result when status is completed" do
      result = %{"data" => "final"}

      session = %GuidedSession{
        client: self(),
        session_id: "s1",
        state: %Types.GuideState{status: "completed", result: result}
      }

      assert {:ok, ^result} = GuidedSession.complete(session)
    end

    test "returns error when status is not completed" do
      session = %GuidedSession{
        client: self(),
        session_id: "s1",
        state: %Types.GuideState{status: "in_progress"}
      }

      assert {:error, {:not_completed, "in_progress"}} = GuidedSession.complete(session)
    end
  end
end
