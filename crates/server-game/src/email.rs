//! Minimal Resend client. Content lives in `crates/server-game/emails/*.txt`
//! — plain text, `{{placeholder}}` substitution, no conditionals or loops —
//! deliberately not a real templating engine, since these are all flat "hi
//! X, here's a link" emails and a template-engine dependency would be
//! solving a problem this project doesn't have. Editing the wording is a
//! content change to those files, not a code change here.

use serde_json::json;

#[derive(Clone)]
pub struct EmailConfig {
    /// `None` means no provider is configured (local dev, or the operator
    /// simply hasn't set `RESEND_API_KEY` yet) — `send` degrades to logging
    /// the full message instead of failing, so every email-triggering flow
    /// keeps working (and stays testable) with zero external dependency.
    api_key: Option<String>,
    from_address: String,
}

impl EmailConfig {
    pub fn new(api_key: Option<String>, from_address: String) -> Self {
        Self {
            api_key,
            from_address,
        }
    }
}

const WELCOME_TEMPLATE: &str = include_str!("../emails/welcome.txt");
const INVITATION_TEMPLATE: &str = include_str!("../emails/invitation.txt");
const JOIN_INVITATION_TEMPLATE: &str = include_str!("../emails/join-invitation.txt");
const PASSWORD_RESET_TEMPLATE: &str = include_str!("../emails/password-reset.txt");
const MOVE_REMINDER_TEMPLATE: &str = include_str!("../emails/move-reminder.txt");

/// What a message is, for the log.
///
/// **The recipient's address is never logged** (#174). `player_id` identifies
/// the account where there is one, and `scripts/admin.sh` resolves it to a
/// person on the rare occasion somebody needs to know — which is the whole
/// "identifiers only" rule applied to the one place that used to carry an
/// address in plain text.
///
/// A closed set rather than a `&str`, because `docs/4.7-log-events.md` declares
/// these values and a test compares them: a free-form string would let a new
/// kind reach the log without the document hearing about it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageKind {
    Welcome,
    Invitation,
    JoinInvitation,
    PasswordReset,
    MoveTimeReminder,
}

impl MessageKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Welcome => "welcome",
            Self::Invitation => "invitation",
            Self::JoinInvitation => "join_invitation",
            Self::PasswordReset => "password_reset",
            Self::MoveTimeReminder => "move_time_reminder",
        }
    }
}

pub async fn send_welcome(
    config: &EmailConfig,
    to: &str,
    player_id: &str,
    display_name: &str,
    base_url: &str,
) {
    let (subject, body) = render(
        WELCOME_TEMPLATE,
        &[("display_name", display_name), ("base_url", base_url)],
    );
    send(
        config,
        to,
        &subject,
        &body,
        MessageKind::Welcome,
        Some(player_id),
    )
    .await;
}

pub async fn send_invitation(
    config: &EmailConfig,
    to: &str,
    player_id: Option<&str>,
    invitee_name: &str,
    inviter_name: &str,
    base_url: &str,
) {
    let (subject, body) = render(
        INVITATION_TEMPLATE,
        &[
            ("invitee_name", invitee_name),
            ("inviter_name", inviter_name),
            ("base_url", base_url),
        ],
    );
    send(
        config,
        to,
        &subject,
        &body,
        MessageKind::Invitation,
        player_id,
    )
    .await;
}

/// Unlike `send_invitation`, `to` has no known `Player` account behind it
/// yet — this is what `SeatClaim::Email` sends instead (see its doc
/// comment), a plain join link rather than "log in to accept".
pub async fn send_join_invitation(
    config: &EmailConfig,
    to: &str,
    inviter_name: &str,
    join_url: &str,
) {
    let (subject, body) = render(
        JOIN_INVITATION_TEMPLATE,
        &[("inviter_name", inviter_name), ("join_url", join_url)],
    );
    // No `player_id`: this is the case where there is deliberately no account
    // behind the address yet, so the log's `player_id` is empty and says so.
    send(
        config,
        to,
        &subject,
        &body,
        MessageKind::JoinInvitation,
        None,
    )
    .await;
}

pub async fn send_password_reset(config: &EmailConfig, to: &str, player_id: &str, reset_url: &str) {
    let (subject, body) = render(PASSWORD_RESET_TEMPLATE, &[("reset_url", reset_url)]);
    send(
        config,
        to,
        &subject,
        &body,
        MessageKind::PasswordReset,
        Some(player_id),
    )
    .await;
}

/// Sent at most once per turn, only once remaining time drops to a third
/// of the game's move-time-limit — see `app::send_move_time_reminders`.
/// `time_remaining` is a pre-formatted label like "1 day 4 hours". Returns
/// whether the send succeeded (or was a legitimate no-op — no provider
/// configured) — unlike `send`'s other callers, this one is a scheduled
/// job that reports its own failures via R5's health numbers rather than
/// failing a player's request, so it is the one caller that needs to know.
pub async fn send_move_time_reminder(
    config: &EmailConfig,
    to: &str,
    player_id: &str,
    display_name: &str,
    time_remaining: &str,
    base_url: &str,
) -> bool {
    let (subject, body) = render(
        MOVE_REMINDER_TEMPLATE,
        &[
            ("display_name", display_name),
            ("time_remaining", time_remaining),
            ("base_url", base_url),
        ],
    );
    send(
        config,
        to,
        &subject,
        &body,
        MessageKind::MoveTimeReminder,
        Some(player_id),
    )
    .await
}

/// Template format: a `Subject: ...` first line, a blank line, then the
/// plain-text body — everything after is verbatim aside from `{{key}}`
/// substitution (applied to both subject and body, since the invitation
/// email's subject line itself uses a placeholder).
fn render(template: &str, values: &[(&str, &str)]) -> (String, String) {
    let (subject_line, body) = template
        .split_once('\n')
        .expect("email template should have a Subject line, a blank line, then the body");
    let subject = subject_line
        .strip_prefix("Subject: ")
        .expect("email template's first line should read 'Subject: ...'");
    let body = body.trim_start_matches('\n');

    let substitute = |text: &str| {
        values.iter().fold(text.to_string(), |acc, (key, value)| {
            acc.replace(&format!("{{{{{key}}}}}"), value)
        })
    };
    (substitute(subject), substitute(body))
}

/// Fire-and-log, never fire-and-fail: a missing/failed send is always a
/// `warn`-level side note, never something that fails the caller's request.
/// Registering, inviting someone, or requesting a password reset should all
/// succeed on their own merits — none of them ought to depend on Resend
/// being reachable, same principle as everything else in this codebase that
/// treats a notification as best-effort rather than load-bearing.
///
/// Returns whether the send succeeded, or was a legitimate no-op (no
/// provider configured) — `false` only for a real failure (a non-2xx
/// response or a transport error). Every caller but
/// `send_move_time_reminder` discards this, which is exactly the
/// fire-and-forget behaviour this doc comment describes; that one caller
/// is a scheduled job reporting its own failures rather than serving a
/// request, so it is the one place the outcome needs to travel further.
async fn send(
    config: &EmailConfig,
    to: &str,
    subject: &str,
    text_body: &str,
    kind: MessageKind,
    player_id: Option<&str>,
) -> bool {
    // Empty rather than absent when there is no account behind the address —
    // a field that is always present keeps `docs/4.7`'s schema simple, and the
    // one case that produces it (a join invitation) is documented there.
    let player_id = player_id.unwrap_or("");

    let Some(api_key) = config.api_key.as_deref() else {
        // The email body is the only place this content exists when there's no
        // provider to deliver it — log it in full (rather than just "would
        // have sent something") so the flow stays usable and testable in local
        // dev with zero Resend setup.
        //
        // **Guarded on an explicit switch as well as on the missing key**
        // (#174). The two used to be the same condition, which meant an unset
        // key in production would have written every reset link and every
        // address into the log. They are different questions — "is there a
        // provider?" and "is this somewhere it is safe to print an email?" —
        // and only the second may turn this on.
        //
        // The switch is an environment variable rather than `debug_assertions`,
        // which is what it was until preview showed the proxy was wrong:
        // preview builds `--release`, so a build-profile guard turned it off in
        // exactly the place it is most useful — reading an invitation link out
        // of the log is how an invitation flow is tested there. Set in
        // `docker-compose.preview.yml` and nowhere else; production would have
        // to opt in by hand, in a file that is reviewed.
        // `cfg!(test)` alongside the variable, because a test process is the
        // original case this exists for — four tests read the message back to
        // assert an invitation reached the right address, and they broke the
        // moment the guard stopped being `debug_assertions`. It cannot leak:
        // `cfg!(test)` is false in every binary that is not a test build.
        if cfg!(test)
            || matches!(
                std::env::var("TILE_LITE_ELITE_LOG_EMAIL_BODIES").as_deref(),
                Ok("1") | Ok("true")
            )
        {
            tracing::info!(
                kind = kind.as_str(),
                player_id,
                to,
                subject,
                text_body,
                "email not sent (no RESEND_API_KEY configured)"
            );
        } else {
            tracing::warn!(
                kind = kind.as_str(),
                player_id,
                "email not sent: no RESEND_API_KEY configured"
            );
        }
        return true;
    };

    let client = reqwest::Client::new();
    let response = client
        .post("https://api.resend.com/emails")
        .bearer_auth(api_key)
        .json(&json!({
            "from": config.from_address,
            "to": [to],
            "subject": subject,
            "text": text_body,
        }))
        .send()
        .await;

    match response {
        Ok(response) if response.status().is_success() => {
            tracing::info!(kind = kind.as_str(), player_id, "email sent");
            true
        }
        Ok(response) => {
            // The provider's response body is dropped: it echoes the request,
            // address included. The status says what went wrong at the level
            // that is actionable, and a specific investigation can add a line
            // for as long as it needs one.
            let status = response.status();
            tracing::warn!(
                kind = kind.as_str(),
                player_id,
                %status,
                "email send failed"
            );
            false
        }
        Err(error) => {
            tracing::warn!(
                kind = kind.as_str(),
                player_id,
                %error,
                "email send failed"
            );
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_substitutes_every_placeholder_in_subject_and_body() {
        let (subject, body) = render(
            "Subject: {{a}} says hi\n\nHello {{b}}, from {{a}}.\n",
            &[("a", "Alice"), ("b", "Bob")],
        );
        assert_eq!(subject, "Alice says hi");
        assert_eq!(body, "Hello Bob, from Alice.\n");
    }

    #[test]
    fn every_template_file_parses_and_leaves_no_placeholder_unfilled() {
        for (template, keys) in [
            (WELCOME_TEMPLATE, &["display_name", "base_url"][..]),
            (
                INVITATION_TEMPLATE,
                &["invitee_name", "inviter_name", "base_url"][..],
            ),
            (JOIN_INVITATION_TEMPLATE, &["inviter_name", "join_url"][..]),
            (PASSWORD_RESET_TEMPLATE, &["reset_url"][..]),
            (
                MOVE_REMINDER_TEMPLATE,
                &["display_name", "time_remaining", "base_url"][..],
            ),
        ] {
            let values: Vec<(&str, &str)> = keys.iter().map(|key| (*key, "x")).collect();
            let (subject, body) = render(template, &values);
            assert!(
                !subject.contains("{{") && !body.contains("{{"),
                "template left an unfilled {{{{placeholder}}}}: subject={subject:?} body={body:?}"
            );
        }
    }
}
