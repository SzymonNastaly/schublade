//! Time as every core of the client reads it: the wall clock in production and a manual clock in
//! tests. Only coordinators and workers read a clock, and their machines receive times as values.

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Milliseconds since the Unix epoch. Every time enters the machines as a field of an event;
/// no pure function reads a clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize)]
pub struct Timestamp(pub i64);

impl Timestamp {
    pub fn after(self, duration: Duration) -> Timestamp {
        Timestamp(
            self.0
                .saturating_add(i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)),
        )
    }

    /// Zero when `earlier` lies after `self`, so a wall clock that moved backwards never makes an
    /// interval look elapsed.
    pub fn elapsed_since(self, earlier: Timestamp) -> Duration {
        Duration::from_millis(u64::try_from(self.0.saturating_sub(earlier.0)).unwrap_or(0))
    }
}

pub trait Clock: Send + Sync {
    fn now(&self) -> Timestamp;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Timestamp {
        let since_epoch = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO);
        Timestamp(i64::try_from(since_epoch.as_millis()).unwrap_or(i64::MAX))
    }
}

/// A clock a test moves by hand, so a scenario that spans hours runs in milliseconds.
#[derive(Debug)]
pub struct ManualClock {
    now: AtomicI64,
}

impl ManualClock {
    pub fn starting_at(now: Timestamp) -> ManualClock {
        ManualClock {
            now: AtomicI64::new(now.0),
        }
    }

    pub fn advance(&self, duration: Duration) {
        self.now.fetch_add(
            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX),
            Ordering::SeqCst,
        );
    }

    pub fn set(&self, now: Timestamp) {
        self.now.store(now.0, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now(&self) -> Timestamp {
        Timestamp(self.now.load(Ordering::SeqCst))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timestamp_never_reports_a_negative_elapsed_interval() {
        let earlier = Timestamp(1_000);
        let later = earlier.after(Duration::from_millis(2_500));
        assert_eq!(later, Timestamp(3_500));
        assert_eq!(later.elapsed_since(earlier), Duration::from_millis(2_500));
        assert_eq!(earlier.elapsed_since(later), Duration::ZERO);
    }

    #[test]
    fn a_manual_clock_moves_only_when_told() {
        let clock = ManualClock::starting_at(Timestamp(1_000));
        assert_eq!(clock.now(), Timestamp(1_000));
        clock.advance(Duration::from_secs(5));
        assert_eq!(clock.now(), Timestamp(6_000));
        clock.set(Timestamp(42));
        assert_eq!(clock.now(), Timestamp(42));
    }

    #[test]
    fn the_system_clock_reads_the_present() {
        let now = SystemClock.now();
        assert!(now > Timestamp(1_700_000_000_000), "{now:?}");
    }
}
