use serde::{Deserialize, Serialize};

use crate::application::vocabulary::dto::vocabulary_dto::SuggestWordResponse;
use crate::common::error::AppError;
use crate::common::result::AppResult;

// ── OpenAI wire types ─────────────────────────────────────────────────────────

#[derive(Serialize)]
struct OpenAiRequest {
    model: String,
    messages: Vec<Message>,
    response_format: ResponseFormat,
}

#[derive(Serialize)]
struct Message {
    role: String,
    content: String,
}

#[derive(Serialize)]
struct ResponseFormat {
    r#type: String,
}

#[derive(Deserialize)]
struct OpenAiResponse {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: MessageContent,
}

#[derive(Deserialize)]
struct MessageContent {
    content: String,
}

#[derive(Deserialize)]
struct SuggestPayload {
    vietnamese_meaning: String,
    phonetic: String,
    examples: Vec<String>,
}

// ── Command ───────────────────────────────────────────────────────────────────

pub async fn handle(word: &str) -> AppResult<SuggestWordResponse> {
    let api_key = std::env::var("OPENAI_API_KEY")
        .map_err(|_| AppError::Internal(anyhow::anyhow!("OPENAI_API_KEY not configured")))?;

    let prompt = format!(
        r#"You are an English-Vietnamese vocabulary assistant.
Given the English word "{word}", return a JSON object with exactly these fields:
- "vietnamese_meaning": a concise Vietnamese translation (1–2 short phrases)
- "phonetic": the IPA pronunciation (e.g. /æmˈbɪʃəs/)
- "examples": an array of exactly 2 natural English example sentences, each followed by " → " and its Vietnamese translation

Return ONLY valid JSON, no markdown, no explanation.
Example output for "ambitious":
{{"vietnamese_meaning":"tham vọng, đầy hoài bão","phonetic":"/æmˈbɪʃəs/","examples":["She is an ambitious student. → Cô ấy là một học sinh đầy hoài bão.","His ambitious plan surprised everyone. → Kế hoạch đầy tham vọng của anh ấy khiến mọi người ngạc nhiên."]}}"#,
        word = word
    );

    let client = reqwest::Client::new();
    let body = OpenAiRequest {
        model: "gpt-4o-mini".to_string(),
        messages: vec![Message {
            role: "user".to_string(),
            content: prompt,
        }],
        response_format: ResponseFormat {
            r#type: "json_object".to_string(),
        },
    };

    let response = client
        .post("https://api.openai.com/v1/chat/completions")
        .bearer_auth(&api_key)
        .json(&body)
        .send()
        .await
        .map_err(|e| AppError::Internal(anyhow::anyhow!("OpenAI request failed: {}", e)))?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(AppError::Internal(anyhow::anyhow!(
            "OpenAI error {}: {}",
            status,
            text
        )));
    }

    let openai_resp: OpenAiResponse = response.json().await.map_err(|e| {
        AppError::Internal(anyhow::anyhow!("Failed to parse OpenAI response: {}", e))
    })?;

    let content = openai_resp
        .choices
        .into_iter()
        .next()
        .ok_or_else(|| AppError::Internal(anyhow::anyhow!("Empty choices from OpenAI")))?
        .message
        .content;

    let payload: SuggestPayload = serde_json::from_str(&content).map_err(|e| {
        AppError::Internal(anyhow::anyhow!("Failed to parse suggestion JSON: {}", e))
    })?;

    Ok(SuggestWordResponse {
        word: word.to_string(),
        vietnamese_meaning: payload.vietnamese_meaning,
        phonetic: payload.phonetic,
        examples: payload.examples,
    })
}
