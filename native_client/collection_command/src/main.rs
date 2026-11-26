//! `schublade-collector`: the command-line program over `collection_core`. It connects an archive,
//! enrolls folders, waits for a survey, decides a backlog, collects in the foreground, and prints
//! the status. On macOS the token lives in the Keychain; `SCHUBLADE_INGEST_TOKEN` replaces it
//! anywhere, and is the only store on Linux.

use std::io::Read;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use archive_access::{ArchiveAddress, ArchiveToken, CredentialStore, FixedCredentialStore, TOKEN_ENVIRONMENT_VARIABLE};
use collection_core::folder_admission::FolderAdmission;
use collection_core::{
    Clock, Collector, CollectorEvent, CollectorSettings, CollectorStatus, ConnectionStatus, EmptyDocumentReader,
    SystemClock, Timestamp,
};

const USAGE: &str = "usage: schublade-collector [--database <path>] <command> [arguments]

commands:
  connect <address>         reads the ingest token from SCHUBLADE_INGEST_TOKEN or standard input
  enroll <folder>...        enrolls each folder; its backlog awaits a decision
  survey                    waits until every folder's survey is complete, then prints the counts
  decide --submit-backlog   uploads the backlog of every folder whose survey is complete
  collect [--until-idle]    collects in the foreground; --until-idle exits once nothing remains
  status [--json]           prints the status

The state database defaults to the application support directory of this user.";

/// How long `wait_until_idle` may block before the program reports no progress.
const IDLE_TIMEOUT: Duration = Duration::from_secs(600);
/// A deadline this near is waited for by `survey` and `collect --until-idle`; a later one, such
/// as a retry in hours, ends the command.
const IMMINENT: Duration = Duration::from_secs(60);

enum Command {
    Connect { address: String },
    Enroll { folders: Vec<PathBuf> },
    Survey,
    Decide,
    Collect { until_idle: bool },
    Status { json: bool },
}

struct Invocation {
    database: PathBuf,
    command: Command,
}

fn parse_arguments(arguments: &[String]) -> Result<Invocation, String> {
    let mut database = None;
    let mut rest = arguments;
    while let Some((first, remaining)) = rest.split_first() {
        match first.as_str() {
            "--database" => {
                let (path, remaining) = remaining.split_first().ok_or("--database needs a path")?;
                database = Some(PathBuf::from(path));
                rest = remaining;
            }
            _ => break,
        }
    }
    let (name, operands) = rest.split_first().ok_or("a command is required")?;
    let flag_only = |flag: &str| -> Result<bool, String> {
        match operands {
            [] => Ok(false),
            [one] if one == flag => Ok(true),
            _ => Err(format!("{name} takes only {flag}")),
        }
    };
    let command = match name.as_str() {
        "connect" => match operands {
            [address] => Command::Connect {
                address: address.clone(),
            },
            _ => return Err("connect takes exactly one archive address".to_owned()),
        },
        "enroll" if !operands.is_empty() => Command::Enroll {
            folders: operands.iter().map(PathBuf::from).collect(),
        },
        "enroll" => return Err("enroll takes at least one folder".to_owned()),
        "survey" if operands.is_empty() => Command::Survey,
        "decide" if operands == ["--submit-backlog"] => Command::Decide,
        "decide" => return Err("decide needs --submit-backlog, the one decision there is".to_owned()),
        "collect" => Command::Collect {
            until_idle: flag_only("--until-idle")?,
        },
        "status" => Command::Status {
            json: flag_only("--json")?,
        },
        other => return Err(format!("unknown command {other}")),
    };
    Ok(Invocation {
        database: database.unwrap_or_else(default_database_path),
        command,
    })
}

fn default_database_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let support = if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Schublade collector")
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/share"))
            .join("schublade-collector")
    };
    support.join("collector.sqlite")
}

/// The Keychain on macOS unless the environment names a token, which wins everywhere.
fn credential_store() -> Box<dyn CredentialStore> {
    if std::env::var_os(TOKEN_ENVIRONMENT_VARIABLE).is_some() {
        return Box::new(FixedCredentialStore::from_environment());
    }
    #[cfg(target_os = "macos")]
    {
        Box::new(archive_access::KeychainCredentialStore::new("Schublade collector"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Box::new(FixedCredentialStore::from_environment())
    }
}

fn read_token() -> Result<ArchiveToken, String> {
    if let Ok(token) = std::env::var(TOKEN_ENVIRONMENT_VARIABLE)
        && !token.trim().is_empty()
    {
        return Ok(ArchiveToken::new(token));
    }
    let mut token = String::new();
    std::io::stdin()
        .read_to_string(&mut token)
        .map_err(|error| format!("could not read the token from standard input: {error}"))?;
    if token.trim().is_empty() {
        return Err(format!(
            "pass the ingest token on standard input or in {TOKEN_ENVIRONMENT_VARIABLE}"
        ));
    }
    Ok(ArchiveToken::new(token))
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let invocation = match parse_arguments(&arguments) {
        Ok(invocation) => invocation,
        Err(problem) => {
            eprintln!("schublade-collector: {problem}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(invocation) {
        Ok(()) => ExitCode::SUCCESS,
        Err(problem) => {
            eprintln!("schublade-collector: {problem}");
            ExitCode::FAILURE
        }
    }
}

fn run(invocation: Invocation) -> Result<(), String> {
    if let Some(directory) = invocation.database.parent() {
        std::fs::create_dir_all(directory).map_err(|error| format!("{}: {error}", directory.display()))?;
    }
    let token = match &invocation.command {
        Command::Connect { .. } => Some(read_token()?),
        _ => None,
    };
    let settings = CollectorSettings::new(invocation.database, credential_store(), Arc::new(EmptyDocumentReader));
    let (collector, events) = Collector::start(settings).map_err(|failure| failure.to_string())?;
    let outcome = match invocation.command {
        Command::Connect { address } => {
            let address = ArchiveAddress::parse(&address).map_err(|refusal| refusal.detail)?;
            let token = token.ok_or("the token was read already")?;
            collector
                .connect_archive(address.clone(), token)
                .map_err(|refusal| refusal.to_string())?;
            println!("Connected to {}", address.origin());
            Ok(())
        }
        Command::Enroll { folders } => {
            for root in folders {
                let folder = collector
                    .enroll_folder(root.clone())
                    .map_err(|refusal| refusal.to_string())?;
                println!("Enrolled {} as folder {}", root.display(), folder.value());
            }
            Ok(())
        }
        Command::Survey => survey(&collector),
        Command::Decide => decide(&collector),
        Command::Collect { until_idle: true } => collect_until_idle(&collector),
        Command::Collect { until_idle: false } => collect(&collector, events),
        Command::Status { json } => {
            let status = collector.status().map_err(|refusal| refusal.to_string())?;
            print_status(&status, json)
        }
    };
    collector.shutdown();
    outcome
}

/// Waits while the collector works or has a deadline within the next minute. Returns the status
/// at which it stopped waiting.
fn settle(collector: &Collector, stop: impl Fn(&CollectorStatus) -> bool) -> Result<CollectorStatus, String> {
    loop {
        let status = collector
            .wait_until_idle(IDLE_TIMEOUT)
            .map_err(|refusal| refusal.to_string())?;
        if stop(&status) {
            return Ok(status);
        }
        let now = SystemClock.now();
        match status.next_scheduled_at {
            Some(at) if at.elapsed_since(now) <= IMMINENT => {
                std::thread::sleep(at.elapsed_since(now) + Duration::from_millis(50));
            }
            _ => return Ok(status),
        }
    }
}

fn survey(collector: &Collector) -> Result<(), String> {
    let surveyed = |status: &CollectorStatus| {
        status
            .folders
            .iter()
            .all(|folder| folder.admission != FolderAdmission::Surveying)
            || !matches!(
                status.connection,
                ConnectionStatus::Connected { .. } | ConnectionStatus::Checking
            )
    };
    let status = settle(collector, surveyed)?;
    print_status(&status, false)?;
    if status
        .folders
        .iter()
        .any(|folder| folder.admission == FolderAdmission::Surveying)
    {
        return Err("the survey is not complete; the connection or a folder needs attention".to_owned());
    }
    Ok(())
}

fn decide(collector: &Collector) -> Result<(), String> {
    let status = collector.status().map_err(|refusal| refusal.to_string())?;
    let Some(backlog) = status.backlog else {
        return Err("no folder awaits a decision; run survey first".to_owned());
    };
    collector
        .decide_backlog(&backlog.folders)
        .map_err(|refusal| refusal.to_string())?;
    println!(
        "Uploading {} files holding {} new contents from {} folders; new files in these folders upload without asking.",
        backlog.files_new,
        backlog.new_contents,
        backlog.folders.len()
    );
    Ok(())
}

fn collect_until_idle(collector: &Collector) -> Result<(), String> {
    let status = settle(collector, |_| false)?;
    print_status(&status, false)
}

/// Runs until the process is interrupted, printing each document the archive receives.
fn collect(collector: &Collector, events: std::sync::mpsc::Receiver<CollectorEvent>) -> Result<(), String> {
    let status = collector.status().map_err(|refusal| refusal.to_string())?;
    print_status(&status, false)?;
    println!("Collecting; interrupt to stop.");
    for event in events {
        if let CollectorEvent::DocumentReceived {
            document_link,
            file_name,
        } = event
        {
            println!("Received {file_name}: {document_link}");
        }
    }
    Ok(())
}

fn print_status(status: &CollectorStatus, json: bool) -> Result<(), String> {
    if json {
        let text = serde_json::to_string_pretty(status).map_err(|error| error.to_string())?;
        println!("{text}");
        return Ok(());
    }
    let connection = match &status.connection {
        ConnectionStatus::Unconfigured => "no archive connected".to_owned(),
        ConnectionStatus::Connected { archive_origin } => format!("connected to {archive_origin}"),
        ConnectionStatus::Unreachable { next_attempt_at, .. } => {
            format!("archive unreachable, next attempt at {}", clock_text(*next_attempt_at))
        }
        ConnectionStatus::Checking => "checking the archive".to_owned(),
        ConnectionStatus::Deferred { until } => format!("archive asked to wait until {}", clock_text(*until)),
        ConnectionStatus::Suspended { reason, .. } => format!("suspended, the token was refused ({reason:?})"),
    };
    println!("Archive: {connection}");
    for folder in &status.folders {
        let admission = match folder.admission {
            FolderAdmission::Surveying => "surveying".to_owned(),
            FolderAdmission::AwaitingDecision => "awaiting the decision".to_owned(),
            FolderAdmission::Collecting { .. } => "collecting".to_owned(),
        };
        println!(
            "Folder {}: {} ({admission}, {:?}, {} files under examination)",
            folder.folder.value(),
            folder.root.display(),
            folder.availability,
            folder.files_under_examination
        );
    }
    if let Some(backlog) = &status.backlog {
        println!(
            "Backlog: {} files, {} already in the archive, {} new holding {} distinct contents, {} excluded, {} disregarded",
            backlog.candidate_files,
            backlog.files_already_archived,
            backlog.files_new,
            backlog.new_contents,
            backlog.excluded_files,
            backlog.disregarded_files.values().sum::<u64>()
        );
    }
    let counts = &status.counts;
    println!(
        "Contents: {} awaiting submission, {} present, {} deleted, {} refused, {} failing",
        counts.contents_awaiting_submission,
        counts.contents_present,
        counts.contents_deleted,
        counts.contents_refused,
        counts.contents_failing
    );
    for item in &status.attention {
        println!("Attention: {item:?}");
    }
    for receipt in &status.recent_receipts {
        println!("Received {}: {}", receipt.file_name, receipt.document_link);
    }
    Ok(())
}

/// Unix milliseconds as seconds since the epoch, which a shell's `date -d @` reads.
fn clock_text(at: Timestamp) -> String {
    format!("{} (Unix seconds)", at.0 / 1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(arguments: &[&str]) -> Result<Invocation, String> {
        parse_arguments(
            &arguments
                .iter()
                .map(|argument| (*argument).to_owned())
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn the_arguments_name_the_database_then_one_command_with_its_operands() {
        let invocation = parse(&["--database", "/tmp/state.sqlite", "enroll", "/a", "/b"]).unwrap();
        assert_eq!(invocation.database, PathBuf::from("/tmp/state.sqlite"));
        assert!(matches!(invocation.command, Command::Enroll { folders } if folders.len() == 2));
        assert!(matches!(
            parse(&["connect", "https://a.example"]).unwrap().command,
            Command::Connect { .. }
        ));
        assert!(matches!(parse(&["survey"]).unwrap().command, Command::Survey));
        assert!(matches!(
            parse(&["decide", "--submit-backlog"]).unwrap().command,
            Command::Decide
        ));
        assert!(matches!(
            parse(&["collect", "--until-idle"]).unwrap().command,
            Command::Collect { until_idle: true }
        ));
        assert!(matches!(
            parse(&["status", "--json"]).unwrap().command,
            Command::Status { json: true }
        ));
        assert!(parse(&["status"]).unwrap().database.ends_with("collector.sqlite"));
        for refused in [
            &[][..],
            &["--database"],
            &["enroll"],
            &["decide"],
            &["connect"],
            &["status", "--yaml"],
            &["survey", "now"],
            &["archive"],
        ] {
            assert!(parse(refused).is_err(), "{refused:?}");
        }
    }
}
