/// Derive a topic/subject name from an outbox event type.
///
/// Convention: `identity.user_registered` -> NATS subject `identity.user-registered`
/// For Kafka the same string is used as the topic name.
pub fn topic_for_event(aggregate_type: &str, event_type: &str) -> String {
    format!(
        "{}.{}",
        aggregate_type.to_lowercase(),
        event_type.to_lowercase().replace('_', "-")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topic_derivation() {
        assert_eq!(
            topic_for_event("Identity", "UserRegistered"),
            "identity.userregistered"
        );
    }

    #[test]
    fn topic_with_underscores() {
        assert_eq!(
            topic_for_event("identity", "user_registered"),
            "identity.user-registered"
        );
    }
}
