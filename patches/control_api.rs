//! Opt-in loopback control API for desktop provider selection.

use axum::{
    extract::{DefaultBodyLimit, Path, State},
    http::{header, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{net::Ipv4Addr, str::FromStr, sync::Arc};
use tauri::{Emitter, Manager};

use crate::{
    app_config::AppType, provider::Provider, services::provider::ProviderService, AppState,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ControlConfig {
    #[serde(default)]
    enabled: bool,
    port: u16,
    token: String,
    allowed_apps: Vec<String>,
}

impl ControlConfig {
    fn validate(&self) -> Result<(), String> {
        if self.port == 0
            || self.token.len() < 32
            || !self.token.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(
                "control API requires a port and a hex token of at least 32 characters".into(),
            );
        }
        if self.allowed_apps.is_empty()
            || self
                .allowed_apps
                .iter()
                .any(|app| AppType::from_str(app).is_err())
        {
            return Err("control API requires an explicit application allowlist".into());
        }
        Ok(())
    }
}

#[derive(Clone)]
struct ControlState {
    handle: tauri::AppHandle,
    allowed_apps: Vec<String>,
}

#[derive(Serialize)]
struct ProviderSummary {
    id: String,
    name: String,
    model: String,
    models: Vec<String>,
    selectable: bool,
}

fn summarize(provider: &Provider, app: &AppType) -> ProviderSummary {
    let model = match app {
        AppType::Codex => {
            crate::proxy::providers::codex_provider_upstream_model(provider).unwrap_or_default()
        }
        _ => provider
            .settings_config
            .pointer("/env/ANTHROPIC_MODEL")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
    };
    let mut models = Vec::new();
    if !model.is_empty() {
        models.push(model.clone());
    }
    if app == &AppType::Codex {
        for catalog_model in provider
            .settings_config
            .pointer("/modelCatalog/models")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|entry| entry.get("model").and_then(serde_json::Value::as_str))
            .map(str::trim)
            .filter(|catalog_model| !catalog_model.is_empty())
        {
            if !models.iter().any(|existing| existing == catalog_model) {
                models.push(catalog_model.to_string());
            }
        }
    }
    if app == &AppType::Claude {
        for key in [
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
        ] {
            if let Some(value) = provider
                .settings_config
                .pointer(&format!("/env/{key}"))
                .and_then(|v| v.as_str())
                .filter(|v| !v.is_empty())
            {
                if !models.iter().any(|existing| existing == value) {
                    models.push(value.to_string());
                }
            }
        }
    }
    if app == &AppType::Pi {
        for pi_model in provider
            .settings_config
            .pointer("/models")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|entry| entry.get("id").and_then(serde_json::Value::as_str))
            .map(str::trim)
            .filter(|pi_model| !pi_model.is_empty())
        {
            if !models.iter().any(|existing| existing == pi_model) {
                models.push(pi_model.to_string());
            }
        }
    }
    ProviderSummary {
        id: provider.id.clone(),
        name: provider.name.clone(),
        model,
        models,
        selectable: provider.category.as_deref() != Some("official")
            || crate::services::provider::official_provider_supports_proxy_takeover(app, provider),
    }
}

#[derive(Serialize)]
struct Catalog {
    current_id: String,
    providers: Vec<ProviderSummary>,
    /// False for apps CC Switch configures directly (e.g. Pi); switching then rewrites
    /// the app's own config instead of retargeting the local proxy.
    proxy_managed: bool,
    proxy_running: bool,
    auto_failover: bool,
}

type ApiError = (StatusCode, Json<serde_json::Value>);

fn error(status: StatusCode, code: &str) -> ApiError {
    (status, Json(json!({"error": code})))
}

fn allowed_app(state: &ControlState, app: &str) -> Result<AppType, ApiError> {
    if !state.allowed_apps.iter().any(|allowed| allowed == app) {
        return Err(error(StatusCode::FORBIDDEN, "application_not_allowed"));
    }
    AppType::from_str(app).map_err(|_| error(StatusCode::BAD_REQUEST, "invalid_application"))
}

async fn catalog(state: &AppState, app: AppType) -> Result<Catalog, ApiError> {
    let current_id = ProviderService::current(state, app.clone())
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "read_failed"))?;
    let mut providers: Vec<_> = state
        .db
        .get_all_providers(app.as_str())
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "read_failed"))?
        .into_values()
        .collect();
    providers.sort_by(|a, b| {
        a.sort_index
            .unwrap_or(usize::MAX)
            .cmp(&b.sort_index.unwrap_or(usize::MAX))
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.id.cmp(&b.id))
    });
    let proxy_managed = app.supports_local_proxy();
    let (proxy_running, auto_failover) = if proxy_managed {
        let proxy = state
            .db
            .get_proxy_config_for_app(app.as_str())
            .await
            .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "read_failed"))?;
        (
            state.proxy_service.is_running().await && proxy.enabled,
            proxy.auto_failover_enabled,
        )
    } else {
        (false, false)
    };
    Ok(Catalog {
        current_id,
        providers: providers.iter().map(|p| summarize(p, &app)).collect(),
        proxy_managed,
        proxy_running,
        auto_failover,
    })
}

async fn list(
    State(control): State<ControlState>,
    Path(app): Path<String>,
) -> Result<Json<Catalog>, ApiError> {
    let app = allowed_app(&control, &app)?;
    let state = control.handle.state::<AppState>();
    catalog(state.inner(), app).await.map(Json)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelSelection {
    id: String,
    model: String,
    /// Which Claude Code tiers to remap. Default: every tier plus subagent and fallback.
    #[serde(default)]
    tiers: Vec<String>,
}

const ALL_TIERS: [&str; 6] = ["haiku", "sonnet", "opus", "fable", "subagent", "default"];

fn tier_env_keys(tier: &str) -> Option<(&'static str, Option<&'static str>)> {
    match tier {
        "haiku" => Some(("ANTHROPIC_DEFAULT_HAIKU_MODEL", Some("ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"))),
        "sonnet" => Some(("ANTHROPIC_DEFAULT_SONNET_MODEL", Some("ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"))),
        "opus" => Some(("ANTHROPIC_DEFAULT_OPUS_MODEL", Some("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"))),
        "fable" => Some(("ANTHROPIC_DEFAULT_FABLE_MODEL", Some("ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"))),
        "subagent" => Some(("CLAUDE_CODE_SUBAGENT_MODEL", None)),
        "default" => Some(("ANTHROPIC_MODEL", None)),
        _ => None,
    }
}

fn valid_model_name(model: &str) -> bool {
    !model.is_empty()
        && model.len() <= 128
        && model
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b" ._:/-[]".contains(&b))
}

async fn select(
    State(control): State<ControlState>,
    Path(app): Path<String>,
    Json(selection): Json<Selection>,
) -> Result<Json<Catalog>, ApiError> {
    let app_type = allowed_app(&control, &app)?;
    let state = control.handle.state::<AppState>();
    let updated = apply_selection(state.inner(), Some(&control.handle), app_type, &selection.id).await?;
    let _ = control.handle.emit(
        "provider-switched",
        json!({"appType": app, "providerId": selection.id}),
    );
    if let Ok(menu) =
        crate::tray::create_tray_menu(&control.handle, control.handle.state::<AppState>().inner())
    {
        if let Some(tray) = control.handle.tray_by_id(crate::tray::TRAY_ID) {
            if let Err(err) = tray.set_menu(Some(menu)) {
                log::warn!("control API: tray refresh failed: {err}");
            }
        }
    }
    Ok(Json(updated))
}

async fn apply_selection(
    state: &AppState,
    handle: Option<&tauri::AppHandle>,
    app: AppType,
    id: &str,
) -> Result<Catalog, ApiError> {
    if id.is_empty() || id.len() > 256 {
        return Err(error(StatusCode::BAD_REQUEST, "invalid_provider_id"));
    }
    let before = catalog(state, app.clone()).await?;
    let provider = before
        .providers
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "provider_not_found"))?;

    if !before.proxy_managed {
        // Direct-config apps (Pi, OpenCode, ...): reuse the desktop's regular switch path,
        // which rewrites the app's own config files. Like the desktop command, run it on
        // the blocking pool because it blocks internally.
        let outcome: Result<(), String> = match handle {
            Some(handle) => {
                let handle = handle.clone();
                let app_for_switch = app.clone();
                let id_for_switch = id.to_string();
                tauri::async_runtime::spawn_blocking(move || -> Result<(), String> {
                    let state = handle
                        .try_state::<AppState>()
                        .ok_or_else(|| "app state unavailable".to_string())?;
                    ProviderService::switch(state.inner(), app_for_switch, &id_for_switch)
                        .map(|_| ())
                        .map_err(|e| e.to_string())
                })
                .await
                .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "switch_failed"))?
            }
            None => ProviderService::switch(state, app.clone(), id)
                .map(|_| ())
                .map_err(|e| e.to_string()),
        };
        outcome.map_err(|err| {
            log::warn!("control API: direct switch failed: {err}");
            error(StatusCode::CONFLICT, "switch_failed")
        })?;
        return catalog(state, app).await;
    }

    if !before.proxy_running {
        return Err(error(StatusCode::CONFLICT, "proxy_not_running"));
    }
    if before.auto_failover {
        return Err(error(StatusCode::CONFLICT, "auto_failover_enabled"));
    }
    if !provider.selectable {
        return Err(error(StatusCode::CONFLICT, "provider_not_proxy_compatible"));
    }
    // This is the guarded transaction used by the desktop's switch_proxy_provider command.
    state
        .proxy_service
        .switch_proxy_target(app.as_str(), id)
        .await
        .map_err(|_| error(StatusCode::CONFLICT, "switch_failed"))?;
    catalog(state, app).await
}

async fn model_selection(
    State(control): State<ControlState>,
    Path(app): Path<String>,
    Json(selection): Json<ModelSelection>,
) -> Result<Json<Catalog>, ApiError> {
    let app_type = allowed_app(&control, &app)?;
    let state = control.handle.state::<AppState>();
    let updated = apply_model_selection(
        state.inner(),
        app_type,
        &selection.id,
        &selection.model,
        &selection.tiers,
    )
    .await?;
    let _ = control.handle.emit(
        "provider-switched",
        json!({
            "appType": app,
            "providerId": selection.id,
            "model": selection.model
        }),
    );
    Ok(Json(updated))
}

/// Claude: remaps the provider's Claude Code tiers to `model`. The proxy classifies incoming
/// requests by tier name (haiku/sonnet/opus/fable), so `ANTHROPIC_MODEL` alone would only
/// affect requests that carry none of those words.
/// Codex: sets the provider's upstream model (the proxy rewrites every request to it).
async fn apply_model_selection(
    state: &AppState,
    app: AppType,
    id: &str,
    model: &str,
    tiers: &[String],
) -> Result<Catalog, ApiError> {
    if id.is_empty() || id.len() > 256 {
        return Err(error(StatusCode::BAD_REQUEST, "invalid_provider_id"));
    }
    if !valid_model_name(model) {
        return Err(error(StatusCode::BAD_REQUEST, "invalid_model"));
    }
    if !matches!(app, AppType::Claude | AppType::Codex) {
        return Err(error(StatusCode::FORBIDDEN, "application_not_allowed"));
    }
    let tiers: Vec<&str> = if tiers.is_empty() {
        ALL_TIERS.to_vec()
    } else {
        tiers.iter().map(String::as_str).collect()
    };
    if app == AppType::Claude && tiers.iter().any(|t| tier_env_keys(t).is_none()) {
        return Err(error(StatusCode::BAD_REQUEST, "invalid_tier"));
    }

    let before = catalog(state, app.clone()).await?;
    let mut provider = state
        .db
        .get_provider_by_id(id, app.as_str())
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "read_failed"))?
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "provider_not_found"))?;
    if !before.proxy_running {
        return Err(error(StatusCode::CONFLICT, "proxy_not_running"));
    }
    if before.auto_failover {
        return Err(error(StatusCode::CONFLICT, "auto_failover_enabled"));
    }

    let original = provider.clone();
    match app {
        AppType::Claude => {
            let display_name =
                crate::proxy::model_mapper::strip_one_m_suffix_for_upstream(model).to_string();
            if !provider
                .settings_config
                .get("env")
                .map(serde_json::Value::is_object)
                .unwrap_or(false)
            {
                provider.settings_config["env"] = json!({});
            }
            let env = provider
                .settings_config
                .get_mut("env")
                .and_then(|value| value.as_object_mut())
                .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "write_failed"))?;
            for tier in tiers {
                if let Some((model_key, name_key)) = tier_env_keys(tier) {
                    env.insert(model_key.into(), json!(model));
                    if let Some(name_key) = name_key {
                        env.insert(name_key.into(), json!(display_name));
                    }
                }
            }
        }
        AppType::Codex => {
            if let Some(config) = provider
                .settings_config
                .get("config")
                .and_then(|v| v.as_str())
                .map(str::to_string)
            {
                let updated = crate::codex_config::update_codex_toml_field(&config, "model", model)
                    .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "write_failed"))?;
                provider.settings_config["config"] = json!(updated);
            }
            if provider.settings_config.get("model").is_some() {
                provider.settings_config["model"] = json!(model);
            }
        }
        _ => unreachable!("guarded above"),
    }
    state
        .db
        .save_provider(app.as_str(), &provider)
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "write_failed"))?;

    if before.current_id == id {
        if let Err(switch_error) = state
            .proxy_service
            .switch_proxy_target(app.as_str(), id)
            .await
        {
            log::warn!("control API: model switch failed: {switch_error}");
            return match state.db.save_provider(app.as_str(), &original) {
                Ok(()) => Err(error(StatusCode::CONFLICT, "switch_failed")),
                Err(_) => Err(error(StatusCode::INTERNAL_SERVER_ERROR, "write_failed")),
            };
        }
    }

    catalog(state, app).await
}

#[derive(Serialize)]
struct ModelCatalog {
    id: String,
    /// Models already referenced by the provider's own configuration.
    configured: Vec<String>,
    /// Models advertised by the upstream `/v1/models` endpoint (Claude providers only).
    upstream: Vec<String>,
    upstream_error: Option<String>,
}

/// Lists the models a provider can be mapped to. For Claude providers this also queries
/// the upstream model list with the provider's own credentials; secrets never leave the
/// process.
async fn provider_models(
    State(control): State<ControlState>,
    Path((app, id)): Path<(String, String)>,
) -> Result<Json<ModelCatalog>, ApiError> {
    let app_type = allowed_app(&control, &app)?;
    if id.is_empty() || id.len() > 256 {
        return Err(error(StatusCode::BAD_REQUEST, "invalid_provider_id"));
    }
    let state = control.handle.state::<AppState>();
    let provider = state
        .db
        .get_provider_by_id(&id, app_type.as_str())
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "read_failed"))?
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "provider_not_found"))?;
    let configured = summarize(&provider, &app_type).models;

    let (upstream, upstream_error) = if app_type == AppType::Claude {
        let env = provider.settings_config.get("env");
        let base_url = env
            .and_then(|e| e.get("ANTHROPIC_BASE_URL"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_string();
        let api_key = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]
            .iter()
            .filter_map(|key| env.and_then(|e| e.get(*key)).and_then(|v| v.as_str()))
            .map(str::trim)
            .find(|v| !v.is_empty())
            .unwrap_or_default()
            .to_string();
        if base_url.is_empty() || api_key.is_empty() {
            (Vec::new(), Some("provider has no base URL or key".to_string()))
        } else {
            match crate::services::model_fetch::fetch_models(
                &base_url, &api_key, false, None, None, None, None,
            )
            .await
            {
                Ok(models) => (models.into_iter().map(|m| m.id).collect(), None),
                Err(err) => (Vec::new(), Some(err)),
            }
        }
    } else {
        (Vec::new(), None)
    };

    Ok(Json(ModelCatalog {
        id,
        configured,
        upstream,
        upstream_error,
    }))
}

async fn authorize(
    State(expected): State<Arc<String>>,
    request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    // Browser origins are not clients of this API; no CORS or cookie authentication.
    if request.headers().contains_key(header::ORIGIN) {
        return error(StatusCode::FORBIDDEN, "browser_origin_not_allowed").into_response();
    }
    let supplied = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .as_bytes();
    let expected = expected.as_bytes();
    let valid = supplied.len() == expected.len()
        && supplied
            .iter()
            .zip(expected)
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            == 0;
    if !valid {
        return error(StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let mut response = next.run(request).await;
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    response
}

fn protect(router: Router, token: &str) -> Router {
    router.layer(middleware::from_fn_with_state(
        Arc::new(format!("Bearer {token}")),
        authorize,
    ))
}

pub(crate) fn start(handle: tauri::AppHandle) {
    let path = crate::config::get_app_config_dir().join("control-api.json");
    if !path.exists() {
        return;
    }
    let config = match std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ControlConfig>(&bytes).ok())
    {
        Some(config) if config.enabled => config,
        Some(_) => return,
        None => {
            log::error!("control API configuration is invalid");
            return;
        }
    };
    if let Err(err) = config.validate() {
        log::error!("{err}");
        return;
    }
    let router = Router::new()
        .route("/api/v1/providers/:app", get(list))
        .route("/api/v1/providers/:app/select", post(select))
        .route("/api/v1/providers/:app/model", post(model_selection))
        .route("/api/v1/providers/:app/models/:id", get(provider_models))
        .layer(DefaultBodyLimit::max(4096))
        .with_state(ControlState {
            handle,
            allowed_apps: config.allowed_apps,
        });
    let router = protect(router, &config.token);
    tauri::async_runtime::spawn(async move {
        let listener = match tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, config.port)).await
        {
            Ok(listener) => listener,
            Err(err) => {
                log::error!("control API bind failed: {err}");
                return;
            }
        };
        log::info!(
            "Provider control API listening on 127.0.0.1:{}",
            config.port
        );
        if let Err(err) = axum::serve(listener, router).await {
            log::error!("control API stopped: {err}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_never_serializes_credentials_or_settings() {
        let provider = Provider::with_id(
            "p1".into(),
            "Example".into(),
            json!({
                "env": {"ANTHROPIC_AUTH_TOKEN": "SECRET", "ANTHROPIC_BASE_URL": "https://example.test/?key=SECRET", "ANTHROPIC_MODEL": "model"}
            }),
            None,
        );
        let result = serde_json::to_string(&summarize(&provider, &AppType::Claude)).unwrap();
        assert!(!result.contains("SECRET"));
        assert!(!result.contains("settings"));
        assert!(result.contains("model"));
    }

    #[test]
    fn summary_reads_codex_model_and_keeps_credentials_private() {
        let provider = Provider::with_id(
            "codex-1".into(),
            "Codex example".into(),
            json!({
                "auth": {"OPENAI_API_KEY": "DO-NOT-EXPOSE"},
                "config": "model_provider = \"example\"\nmodel = \"codex-test-model\"\n[model_providers.example]\nbase_url = \"https://example.test/DO-NOT-EXPOSE\"\n",
                "modelCatalog": {"models": [
                    {"model": "codex-test-model"},
                    {"model": "vendor/model-a", "displayName": "DO-NOT-EXPOSE"},
                    {"model": " vendor/model-b ", "reasoningLevels": ["high"]},
                    {"model": "vendor/model-a"},
                    {"model": "vendor/Model-A"}
                ]}
            }),
            None,
        );
        let summary = summarize(&provider, &AppType::Codex);
        assert_eq!(summary.model, "codex-test-model");
        assert_eq!(
            summary.models,
            vec![
                "codex-test-model",
                "vendor/model-a",
                "vendor/model-b",
                "vendor/Model-A"
            ]
        );
        let response = serde_json::to_string(&summary).unwrap();
        assert!(!response.contains("DO-NOT-EXPOSE"));
        assert!(!response.contains("base_url"));
        assert!(!response.contains("OPENAI_API_KEY"));
        assert!(!response.contains("modelCatalog"));
        assert!(!response.contains("reasoningLevels"));
    }

    #[test]
    fn summary_ignores_invalid_codex_catalog_entries() {
        for catalog in [
            serde_json::Value::Null,
            json!("not-a-catalog"),
            json!({}),
            json!({"models": null}),
            json!({"models": {"model": "not-an-array"}}),
            json!({"models": [
                null,
                "not-an-entry",
                42,
                {},
                {"id": "not-the-model-field"},
                {"model": 42},
                {"model": ""},
                {"model": " \t\n "}
            ]}),
        ] {
            let provider = Provider::with_id(
                "codex-1".into(),
                "Codex example".into(),
                json!({
                    "config": "model = \"codex-test-model\"\n",
                    "modelCatalog": catalog
                }),
                None,
            );
            assert_eq!(
                summarize(&provider, &AppType::Codex).models,
                vec!["codex-test-model"]
            );
        }
    }

    #[test]
    fn summary_lists_every_codex_catalog_model_without_a_default_or_page_limit() {
        let expected_models: Vec<_> = (0..121)
            .map(|index| format!("vendor/model-{index:03}"))
            .collect();
        let catalog_models: Vec<_> = expected_models
            .iter()
            .map(|model| json!({"model": model, "displayName": "Same display name"}))
            .collect();
        let provider = Provider::with_id(
            "codex-1".into(),
            "Codex example".into(),
            json!({"modelCatalog": {"models": catalog_models}}),
            None,
        );
        let summary = summarize(&provider, &AppType::Codex);
        assert_eq!(summary.model, "");
        assert_eq!(summary.models, expected_models);
    }

    #[test]
    fn model_selection_updates_provider_catalog_and_live_config() {
        let provider = Provider::with_id(
            "p1".into(),
            "Example".into(),
            json!({
                "env": {
                    "ANTHROPIC_API_KEY": "SECRET",
                    "ANTHROPIC_BASE_URL": "https://example.test/?key=SECRET",
                    "ANTHROPIC_MODEL": "model-a",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "model-b"
                }
            }),
            None,
        );
        let summary = summarize(&provider, &AppType::Claude);
        assert_eq!(
            summary.models,
            vec!["model-a".to_string(), "model-b".to_string()]
        );
        assert_eq!(summary.model, "model-a");
    }

    #[tokio::test]
    async fn http_requires_token_rejects_browser_and_never_enables_cors() {
        let router = protect(
            Router::new().route("/test", get(|| async { "ok" })),
            "0123456789abcdef0123456789abcdef",
        );
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let url = format!("http://{}/test", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        for (token, origin, status) in [
            ("", false, 401),
            ("wrong", false, 401),
            ("0123456789abcdef0123456789abcdef", true, 403),
            ("0123456789abcdef0123456789abcdef", false, 200),
        ] {
            let mut req = client.get(&url).bearer_auth(token);
            if origin {
                req = req.header("Origin", "https://example.test");
            }
            let response = req.send().await.unwrap();
            assert_eq!(response.status().as_u16(), status);
            assert!(response
                .headers()
                .get("access-control-allow-origin")
                .is_none());
        }
        task.abort();
    }

    #[test]
    fn config_fails_closed() {
        let mut config = ControlConfig {
            enabled: true,
            port: 15722,
            token: "a".repeat(64),
            allowed_apps: vec!["claude".into()],
        };
        assert!(config.validate().is_ok());
        config.allowed_apps = vec!["*".into()];
        assert!(config.validate().is_err());
        config.allowed_apps = vec!["claude".into()];
        config.token = "short".into();
        assert!(config.validate().is_err());
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn selection_updates_desktop_and_preserves_previous_on_failure() {
        let home = tempfile::TempDir::new().unwrap();
        let previous = std::env::var_os("CC_SWITCH_TEST_HOME");
        let old_home = std::env::var_os("HOME");
        struct RestoreHome(Option<std::ffi::OsString>, Option<std::ffi::OsString>);
        impl Drop for RestoreHome {
            fn drop(&mut self) {
                for (key, value) in [("CC_SWITCH_TEST_HOME", &self.0), ("HOME", &self.1)] {
                    match value {
                        Some(v) => std::env::set_var(key, v),
                        None => std::env::remove_var(key),
                    }
                }
                let _ = crate::settings::reload_settings();
            }
        }
        let _restore = RestoreHome(previous, old_home);
        std::env::set_var("CC_SWITCH_TEST_HOME", home.path());
        std::env::set_var("HOME", home.path());
        crate::settings::reload_settings().unwrap();
        let db = Arc::new(crate::database::Database::memory().unwrap());
        let mut proxy = db.get_proxy_config().await.unwrap();
        proxy.listen_port = 0;
        db.update_proxy_config(proxy).await.unwrap();
        for id in ["first", "second"] {
            db.save_provider("claude", &Provider::with_id(id.into(), id.into(), json!({
                "env": {"ANTHROPIC_API_KEY": "test-only", "ANTHROPIC_BASE_URL": "http://127.0.0.1:1", "ANTHROPIC_MODEL": id}
            }), None)).unwrap();
        }
        db.set_current_provider("claude", "first").unwrap();
        crate::settings::set_current_provider(&AppType::Claude, Some("first")).unwrap();
        crate::config::write_json_file(
            &crate::config::get_claude_settings_path(),
            &json!({"env": {"ANTHROPIC_API_KEY": "test-only", "ANTHROPIC_MODEL": "first"}}),
        )
        .unwrap();
        let state = AppState::new(db.clone());
        assert!(apply_selection(&state, None, AppType::Claude, "second")
            .await
            .is_err());
        state
            .proxy_service
            .set_takeover_for_app("claude", true)
            .await
            .unwrap();
        let result = apply_selection(&state, None, AppType::Claude, "second")
            .await
            .unwrap();
        assert_eq!(result.current_id, "second");
        assert!(result.proxy_running);
        assert_eq!(
            crate::settings::get_current_provider(&AppType::Claude).as_deref(),
            Some("second")
        );
        let backup = db.get_live_backup("claude").await.unwrap().unwrap();
        assert!(backup.original_config.contains("second"));
        assert!(apply_selection(&state, None, AppType::Claude, "deleted")
            .await
            .is_err());
        assert_eq!(
            catalog(&state, AppType::Claude).await.unwrap().current_id,
            "second"
        );
        state.proxy_service.stop_with_restore().await.unwrap();
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn codex_catalog_prefers_desktop_selection_and_switch_keeps_history() {
        let home = tempfile::TempDir::new().unwrap();
        struct RestoreHome(Option<std::ffi::OsString>);
        impl Drop for RestoreHome {
            fn drop(&mut self) {
                match &self.0 {
                    Some(value) => std::env::set_var("CC_SWITCH_TEST_HOME", value),
                    None => std::env::remove_var("CC_SWITCH_TEST_HOME"),
                }
                let _ = crate::settings::reload_settings();
            }
        }
        let _restore = RestoreHome(std::env::var_os("CC_SWITCH_TEST_HOME"));
        std::env::set_var("CC_SWITCH_TEST_HOME", home.path());
        crate::settings::reload_settings().unwrap();
        let db = Arc::new(crate::database::Database::memory().unwrap());
        let mut proxy = db.get_proxy_config().await.unwrap();
        proxy.listen_port = 0;
        db.update_proxy_config(proxy).await.unwrap();
        let config = "model_provider = \"example\"\nmodel = \"codex-test-model\"\n[model_providers.example]\nname = \"Example\"\nbase_url = \"http://127.0.0.1:1/v1\"\nwire_api = \"responses\"\n";
        for id in ["db-marked", "desktop-selected"] {
            db.save_provider(
                "codex",
                &Provider::with_id(
                    id.into(),
                    id.into(),
                    json!({
                        "auth": {"OPENAI_API_KEY": "test-only"}, "config": config,
                        "modelCatalog": {"models": [
                            {"model": format!("catalog-model-{id}")}
                        ]}
                    }),
                    None,
                ),
            )
            .unwrap();
        }
        db.set_current_provider("codex", "db-marked").unwrap();
        crate::settings::set_current_provider(&AppType::Codex, Some("desktop-selected")).unwrap();
        let state = AppState::new(db.clone());
        let before = catalog(&state, AppType::Codex).await.unwrap();
        assert_eq!(before.current_id, "desktop-selected");
        for provider in &before.providers {
            assert_eq!(
                provider.models,
                vec![
                    "codex-test-model".to_string(),
                    format!("catalog-model-{}", provider.id)
                ]
            );
        }
        assert_eq!(
            db.get_current_provider("codex").unwrap().as_deref(),
            Some("db-marked")
        );
        assert!(matches!(
            apply_selection(&state, None, AppType::Codex, "db-marked").await,
            Err((StatusCode::CONFLICT, _))
        ));
        crate::codex_config::write_codex_live_atomic(
            &json!({"OPENAI_API_KEY": "test-only"}),
            Some(config),
        )
        .unwrap();
        let history = home.path().join(".codex/sessions/sentinel.jsonl");
        std::fs::create_dir_all(history.parent().unwrap()).unwrap();
        std::fs::write(&history, "existing conversation\n").unwrap();
        state
            .proxy_service
            .set_takeover_for_app("codex", true)
            .await
            .unwrap();
        let selected = apply_selection(&state, None, AppType::Codex, "db-marked")
            .await
            .unwrap();
        assert_eq!(selected.current_id, "db-marked");
        assert_eq!(
            crate::settings::get_current_provider(&AppType::Codex).as_deref(),
            Some("db-marked")
        );
        assert_eq!(
            std::fs::read_to_string(history).unwrap(),
            "existing conversation\n"
        );
        state.proxy_service.stop_with_restore().await.unwrap();
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn model_selection_updates_current_provider_and_restore_backup() {
        let home = tempfile::TempDir::new().unwrap();
        let previous = std::env::var_os("CC_SWITCH_TEST_HOME");
        let old_home = std::env::var_os("HOME");
        struct RestoreHome(Option<std::ffi::OsString>, Option<std::ffi::OsString>);
        impl Drop for RestoreHome {
            fn drop(&mut self) {
                for (key, value) in [("CC_SWITCH_TEST_HOME", &self.0), ("HOME", &self.1)] {
                    match value {
                        Some(v) => std::env::set_var(key, v),
                        None => std::env::remove_var(key),
                    }
                }
                let _ = crate::settings::reload_settings();
            }
        }
        let _restore = RestoreHome(previous, old_home);
        std::env::set_var("CC_SWITCH_TEST_HOME", home.path());
        std::env::set_var("HOME", home.path());
        crate::settings::reload_settings().unwrap();
        let db = Arc::new(crate::database::Database::memory().unwrap());
        let mut proxy = db.get_proxy_config().await.unwrap();
        proxy.listen_port = 0;
        db.update_proxy_config(proxy).await.unwrap();
        db.save_provider(
            "claude",
            &Provider::with_id(
                "first".into(),
                "first".into(),
                json!({
                    "env": {
                        "ANTHROPIC_API_KEY": "test-only",
                        "ANTHROPIC_BASE_URL": "http://127.0.0.1:1",
                        "ANTHROPIC_MODEL": "model-a",
                        "ANTHROPIC_DEFAULT_SONNET_MODEL": "model-b"
                    }
                }),
                None,
            ),
        )
        .unwrap();
        db.set_current_provider("claude", "first").unwrap();
        crate::settings::set_current_provider(&AppType::Claude, Some("first")).unwrap();
        crate::config::write_json_file(
            &crate::config::get_claude_settings_path(),
            &json!({"env": {"ANTHROPIC_API_KEY": "test-only", "ANTHROPIC_MODEL": "model-a"}}),
        )
        .unwrap();
        let state = AppState::new(db.clone());

        let before = catalog(&state, AppType::Claude).await.unwrap();
        assert!(!before.proxy_running);
        let invalid = apply_model_selection(&state, AppType::Claude, "first", "bad;model", &[]).await;
        assert!(matches!(invalid, Err((StatusCode::BAD_REQUEST, _))));
        let invalid_tier = apply_model_selection(
            &state,
            AppType::Claude,
            "first",
            "model-b",
            &["turbo".to_string()],
        )
        .await;
        assert!(matches!(invalid_tier, Err((StatusCode::BAD_REQUEST, _))));

        state
            .proxy_service
            .set_takeover_for_app("claude", true)
            .await
            .unwrap();
        let result = apply_model_selection(&state, AppType::Claude, "first", "model-b[1M]", &[])
            .await
            .unwrap();
        assert_eq!(result.current_id, "first");
        assert_eq!(result.providers[0].model, "model-b[1M]");
        let provider = db.get_provider_by_id("first", "claude").unwrap().unwrap();
        for key in [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
        ] {
            assert_eq!(
                provider.settings_config.pointer(&format!("/env/{key}")),
                Some(&json!("model-b[1M]")),
                "{key}"
            );
        }
        assert_eq!(
            provider.settings_config.pointer("/env/ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"),
            Some(&json!("model-b"))
        );

        // Single-tier remap leaves the other tiers untouched.
        apply_model_selection(&state, AppType::Claude, "first", "model-c", &["opus".to_string()])
            .await
            .unwrap();
        let provider = db.get_provider_by_id("first", "claude").unwrap().unwrap();
        assert_eq!(
            provider.settings_config.pointer("/env/ANTHROPIC_DEFAULT_OPUS_MODEL"),
            Some(&json!("model-c"))
        );
        assert_eq!(
            provider.settings_config.pointer("/env/ANTHROPIC_DEFAULT_SONNET_MODEL"),
            Some(&json!("model-b[1M]"))
        );

        let live: serde_json::Value =
            crate::config::read_json_file(&crate::config::get_claude_settings_path()).unwrap();
        // Proxy takeover deliberately removes the live model override so the
        // request model can be mapped per provider. The restorable config, not
        // the live proxy config, must contain the selected provider default.
        assert!(live.pointer("/env/ANTHROPIC_MODEL").is_none());
        let backup = db.get_live_backup("claude").await.unwrap().unwrap();
        let restored: serde_json::Value = serde_json::from_str(&backup.original_config).unwrap();
        assert_eq!(
            restored.pointer("/env/ANTHROPIC_MODEL"),
            Some(&json!("model-b[1M]"))
        );
        let encoded = serde_json::to_string(&result).unwrap();
        assert!(!encoded.contains("test-only"));

        assert!(
            apply_model_selection(&state, AppType::Claude, "deleted", "model-b", &[])
                .await
                .is_err()
        );
        state.proxy_service.stop_with_restore().await.unwrap();
    }
}
