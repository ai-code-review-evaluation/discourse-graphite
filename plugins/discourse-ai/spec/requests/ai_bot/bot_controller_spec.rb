# frozen_string_literal: true

RSpec.describe DiscourseAi::AiBot::BotController do
  fab!(:user)
  fab!(:pm_topic) { Fabricate(:private_message_topic) }
  fab!(:pm_post) { Fabricate(:post, topic: pm_topic) }
  fab!(:pm_post2) { Fabricate(:post, topic: pm_topic) }
  fab!(:pm_post3) { Fabricate(:post, topic: pm_topic) }

  before do
    enable_current_plugin
    sign_in(user)
  end

  describe "#show_debug_info" do
    before { SiteSetting.ai_bot_enabled = true }

    it "returns a 403 when the user cannot debug the AI bot conversation" do
      get "/discourse-ai/ai-bot/post/#{pm_post.id}/show-debug-info"
      expect(response.status).to eq(403)
    end

    it "returns debug info if the user can debug the AI bot conversation" do
      user = pm_topic.topic_allowed_users.first.user
      sign_in(user)

      log1 =
        AiApiAuditLog.create!(
          provider_id: 1,
          topic_id: pm_topic.id,
          raw_request_payload: "request",
          raw_response_payload: "response",
          request_tokens: 1,
          response_tokens: 2,
        )

      log2 =
        AiApiAuditLog.create!(
          post_id: pm_post.id,
          provider_id: 1,
          topic_id: pm_topic.id,
          raw_request_payload: "request",
          raw_response_payload: "response",
          request_tokens: 1,
          response_tokens: 2,
        )

      log3 =
        AiApiAuditLog.create!(
          post_id: pm_post2.id,
          provider_id: 1,
          topic_id: pm_topic.id,
          raw_request_payload: "request",
          raw_response_payload: "response",
          request_tokens: 1,
          response_tokens: 2,
        )

      Group.refresh_automatic_groups!
      SiteSetting.ai_bot_debugging_allowed_groups = user.groups.first.id.to_s

      get "/discourse-ai/ai-bot/post/#{pm_post.id}/show-debug-info"
      expect(response.status).to eq(200)

      expect(response.parsed_body["id"]).to eq(log2.id)
      expect(response.parsed_body["next_log_id"]).to eq(log3.id)
      expect(response.parsed_body["prev_log_id"]).to eq(log1.id)
      expect(response.parsed_body["topic_id"]).to eq(pm_topic.id)

      expect(response.parsed_body["request_tokens"]).to eq(1)
      expect(response.parsed_body["response_tokens"]).to eq(2)
      expect(response.parsed_body["raw_request_payload"]).to eq("request")
      expect(response.parsed_body["raw_response_payload"]).to eq("response")

      # return previous post if current has no debug info
      get "/discourse-ai/ai-bot/post/#{pm_post3.id}/show-debug-info"
      expect(response.status).to eq(200)
      expect(response.parsed_body["request_tokens"]).to eq(1)
      expect(response.parsed_body["response_tokens"]).to eq(2)

      # can return debug info by id as well
      get "/discourse-ai/ai-bot/show-debug-info/#{log1.id}"
      expect(response.status).to eq(200)
      expect(response.parsed_body["id"]).to eq(log1.id)
    end
  end

  describe "#stop_streaming_response" do
    let(:redis_stream_key) { "gpt_cancel:#{pm_post.id}" }

    before { Discourse.redis.setex(redis_stream_key, 60, 1) }

    it "returns a 403 when the user cannot see the PM" do
      post "/discourse-ai/ai-bot/post/#{pm_post.id}/stop-streaming"

      expect(response.status).to eq(403)
    end

    it "deletes the key using to track the streaming" do
      sign_in(pm_topic.topic_allowed_users.first.user)

      post "/discourse-ai/ai-bot/post/#{pm_post.id}/stop-streaming"

      expect(response.status).to eq(200)
      expect(Discourse.redis.get(redis_stream_key)).to be_nil
    end
  end

  describe "#show_bot_username" do
    it "returns the username_lower of the selected bot" do
      gpt_35_bot = Fabricate(:llm_model, name: "gpt-3.5-turbo")

      SiteSetting.ai_bot_enabled = true
      toggle_enabled_bots(bots: [gpt_35_bot])

      expected_username =
        DiscourseAi::AiBot::EntryPoint.find_user_from_model("gpt-3.5-turbo").username_lower

      get "/discourse-ai/ai-bot/bot-username", params: { username: gpt_35_bot.name }

      expect(response.status).to eq(200)
      expect(response.parsed_body["bot_username"]).to eq(expected_username)
    end
  end

  describe "#discover" do
    before { SiteSetting.ai_bot_enabled = true }

    fab!(:group)
    fab!(:ai_persona) { Fabricate(:ai_persona, allowed_group_ids: [group.id], default_llm_id: 1) }

    context "when no persona is selected" do
      it "returns a 403" do
        get "/discourse-ai/ai-bot/discover", params: { query: "What is Discourse?" }

        expect(response.status).to eq(403)
      end
    end

    context "when the user doesn't have access to the persona" do
      before { SiteSetting.ai_bot_discover_persona = ai_persona.id }

      it "returns a 403" do
        get "/discourse-ai/ai-bot/discover", params: { query: "What is Discourse?" }

        expect(response.status).to eq(403)
      end
    end

    context "when the user is allowed to use discover" do
      before do
        SiteSetting.ai_bot_discover_persona = ai_persona.id
        group.add(user)
      end

      it "returns a 200 and queues a job to reply" do
        expect {
          get "/discourse-ai/ai-bot/discover", params: { query: "What is Discourse?" }
        }.to change(Jobs::StreamDiscoverReply.jobs, :size).by(1)

        expect(response.status).to eq(200)
      end

      it "retues a 400 if the query is missing" do
        get "/discourse-ai/ai-bot/discover"

        expect(response.status).to eq(400)
      end
    end
  end

  describe "#discover_continue_convo" do
    before { SiteSetting.ai_bot_enabled = true }
    fab!(:group)
    fab!(:llm_model)
    fab!(:ai_persona) do
      persona = Fabricate(:ai_persona, allowed_group_ids: [group.id], default_llm_id: llm_model.id)
      persona.create_user!
      persona
    end
    let(:query) { "What is Discourse?" }
    let(:context) { "Discourse is an open-source discussion platform." }

    context "when the user is allowed to discover" do
      before do
        SiteSetting.ai_bot_discover_persona = ai_persona.id
        group.add(user)
      end

      it "returns a 200 and creates a private message topic" do
        expect {
          post "/discourse-ai/ai-bot/discover/continue-convo",
               params: {
                 user_id: user.id,
                 query: query,
                 context: context,
               }
        }.to change(Topic, :count).by(1)

        expect(response.status).to eq(200)
        expect(response.parsed_body["topic_id"]).to be_present
      end

      it "returns invalid parameters if the user_id is missing" do
        post "/discourse-ai/ai-bot/discover/continue-convo",
             params: {
               query: query,
               context: context,
             }

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include("user_id")
      end

      it "returns invalid parameters if the query is missing" do
        post "/discourse-ai/ai-bot/discover/continue-convo",
             params: {
               user_id: user.id,
               context: context,
             }

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include("query")
      end

      it "returns invalid parameters if the context is missing" do
        post "/discourse-ai/ai-bot/discover/continue-convo",
             params: {
               user_id: user.id,
               query: query,
             }

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include("context")
      end
    end
  end
end
