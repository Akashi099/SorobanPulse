//! Security test suite entry point.
//!
//! Run all security tests:
//!   cargo test --test security
//!
//! Run a specific sub-module:
//!   cargo test --test security owasp_tests
//!   cargo test --test security auth_bypass_tests
//!   cargo test --test security crypto_tests
//!   cargo test --test security regression_tests
//!   cargo test --test security graphql_limit_tests
//!   cargo test --test security problem_detail_tests
//!   cargo test --test security api_key_hashing_tests
//!   cargo test --test security webhook_signature_tests
//!   cargo test --test security client_ip_tests

mod security;

// ---------------------------------------------------------------------------
// Issue #1430: peppered HMAC API-key digests, legacy re-hash, env-key policy.
// ---------------------------------------------------------------------------
mod api_key_hashing_tests {
    use soroban_pulse::middleware::auth::{
        hash_api_key, hash_api_key_with_pepper, is_legacy_sha256_digest, validate_env_api_key,
        EnvKeyPolicy, LEGACY_DIGEST_LEN,
    };

    const PEPPER_A: &str = "pepper-alpha-0123456789abcdef0123456789abcdef";
    const PEPPER_B: &str = "pepper-bravo-fedcba9876543210fedcba9876543210";

    #[test]
    fn peppered_digest_is_not_bare_sha256() {
        let key = "sp_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let peppered = hash_api_key_with_pepper(key, PEPPER_A);
        let legacy = hash_api_key(key);
        assert_ne!(peppered, legacy, "peppered digest must differ from bare SHA-256");
        assert_eq!(peppered.len(), 64, "HMAC-SHA256 hex digest is 64 chars");
    }

    #[test]
    fn peppered_lookup_is_deterministic_for_same_pepper() {
        let key = "sp_deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
        let a = hash_api_key_with_pepper(key, PEPPER_A);
        let b = hash_api_key_with_pepper(key, PEPPER_A);
        assert_eq!(a, b, "same key + same pepper must yield the same digest");
    }

    #[test]
    fn peppered_lookup_fails_after_pepper_rotation_without_rehash() {
        let key = "sp_cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe";
        let old_digest = hash_api_key_with_pepper(key, PEPPER_A);
        let new_digest = hash_api_key_with_pepper(key, PEPPER_B);
        assert_ne!(
            old_digest, new_digest,
            "rotating the pepper must change the digest so old digests cannot be replayed"
        );
    }

    #[test]
    fn pepper_rotation_rehash_is_transparent() {
        // Simulate a stored digest produced under PEPPER_A, then a rotation to
        // PEPPER_B. The lookup helper should accept the old digest once and
        // report that a re-hash is required.
        let key = "sp_1111111111111111111111111111111111111111111111111111111111111111";
        let stored = hash_api_key_with_pepper(key, PEPPER_A);

        let outcome = soroban_pulse::middleware::auth::lookup_with_rotation(
            key,
            &stored,
            PEPPER_B,
            Some(PEPPER_A),
        );
        assert!(
            outcome.matched,
            "key must still authenticate during the rotation window"
        );
        assert!(
            outcome.needs_rehash,
            "lookup must signal that the digest should be re-hashed under the new pepper"
        );
        assert_eq!(
            outcome.rehashed_digest.as_deref(),
            Some(hash_api_key_with_pepper(key, PEPPER_B).as_str()),
            "re-hashed digest must use the active pepper"
        );
    }

    #[test]
    fn legacy_sha256_digest_is_detected_and_rehashed() {
        let key = "sp_2222222222222222222222222222222222222222222222222222222222222222";
        let legacy = hash_api_key(key);
        assert_eq!(legacy.len(), LEGACY_DIGEST_LEN);
        assert!(
            is_legacy_sha256_digest(&legacy),
            "bare SHA-256 hex digest must be recognised as legacy"
        );

        let outcome = soroban_pulse::middleware::auth::lookup_with_rotation(
            key,
            &legacy,
            PEPPER_A,
            None,
        );
        assert!(outcome.matched, "legacy digest must still authenticate once");
        assert!(
            outcome.needs_rehash,
            "legacy digest must be transparently re-hashed on next use"
        );
        assert_eq!(
            outcome.rehashed_digest.as_deref(),
            Some(hash_api_key_with_pepper(key, PEPPER_A).as_str())
        );
    }

    #[test]
    fn wrong_key_does_not_match() {
        let key = "sp_3333333333333333333333333333333333333333333333333333333333333333";
        let stored = hash_api_key_with_pepper(key, PEPPER_A);
        let outcome = soroban_pulse::middleware::auth::lookup_with_rotation(
            "sp_4444444444444444444444444444444444444444444444444444444444444444",
            &stored,
            PEPPER_A,
            None,
        );
        assert!(!outcome.matched);
        assert!(!outcome.needs_rehash);
    }

    #[test]
    fn short_env_key_is_rejected() {
        let policy = EnvKeyPolicy::default();
        let err = validate_env_api_key("API_KEY", "short", &policy);
        assert!(
            err.is_err(),
            "env API keys shorter than the minimum must be rejected"
        );
    }

    #[test]
    fn long_env_key_is_accepted() {
        let policy = EnvKeyPolicy::default();
        let key = "a".repeat(policy.min_length);
        assert!(validate_env_api_key("API_KEY", &key, &policy).is_ok());
    }

    #[test]
    fn generated_sp_key_has_at_least_256_bits() {
        let key = soroban_pulse::middleware::auth::generate_api_key();
        assert!(key.starts_with("sp_"));
        // 32 random bytes -> 64 hex chars after the prefix.
        assert!(
            key.len() >= 3 + 64,
            "generated keys must carry >= 256 bits of randomness, got {} chars",
            key.len()
        );
    }
}

// ---------------------------------------------------------------------------
// Issue #1431: webhook signature v2 (timestamped) + legacy compatibility.
// ---------------------------------------------------------------------------
mod webhook_signature_tests {
    use soroban_pulse::webhook::{
        sign_payload, sign_payload_v2, verify_signature_v1, verify_signature_v2,
        SignatureV2, DEFAULT_TOLERANCE_SECS,
    };

    const SECRET: &str = "whsec_test_secret_value";

    #[test]
    fn fresh_v2_signature_verifies() {
        let body = br#"{"event":"transfer"}"#;
        let now = 1_700_000_000u64;
        let sig = sign_payload_v2(SECRET, body, now);
        assert!(
            verify_signature_v2(SECRET, body, &sig, now, DEFAULT_TOLERANCE_SECS).is_ok(),
            "fresh signature must verify"
        );
    }

    #[test]
    fn stale_v2_signature_is_rejected() {
        let body = br#"{"event":"transfer"}"#;
        let signed_at = 1_700_000_000u64;
        let sig = sign_payload_v2(SECRET, body, signed_at);
        let now = signed_at + DEFAULT_TOLERANCE_SECS + 1;
        assert!(
            verify_signature_v2(SECRET, body, &sig, now, DEFAULT_TOLERANCE_SECS).is_err(),
            "signature older than the tolerance window must be rejected"
        );
    }

    #[test]
    fn future_v2_signature_is_rejected() {
        let body = br#"{"event":"transfer"}"#;
        let now = 1_700_000_000u64;
        let sig = sign_payload_v2(SECRET, body, now + DEFAULT_TOLERANCE_SECS + 1);
        assert!(
            verify_signature_v2(SECRET, body, &sig, now, DEFAULT_TOLERANCE_SECS).is_err(),
            "signature from the future beyond tolerance must be rejected"
        );
    }

    #[test]
    fn tampered_body_fails_v2() {
        let body = br#"{"event":"transfer"}"#;
        let now = 1_700_000_000u64;
        let sig = sign_payload_v2(SECRET, body, now);
        assert!(
            verify_signature_v2(SECRET, br#"{"event":"other"}"#, &sig, now, DEFAULT_TOLERANCE_SECS)
                .is_err()
        );
    }

    #[test]
    fn v2_header_roundtrips() {
        let body = br#"{"event":"transfer"}"#;
        let now = 1_700_000_000u64;
        let sig = sign_payload_v2(SECRET, body, now);
        let header = sig.to_header();
        assert!(header.starts_with("t="));
        assert!(header.contains(",v1="));
        let parsed = SignatureV2::parse(&header).expect("header must parse");
        assert_eq!(parsed.timestamp, now);
        assert_eq!(parsed.signature, sig.signature);
    }

    #[test]
    fn legacy_v1_signature_still_verifies() {
        let body = br#"{"event":"transfer"}"#;
        let legacy = sign_payload(SECRET, body);
        assert!(
            verify_signature_v1(SECRET, body, &legacy).is_ok(),
            "legacy header must remain valid during the deprecation window"
        );
    }

    #[test]
    fn legacy_v1_rejects_wrong_secret() {
        let body = br#"{"event":"transfer"}"#;
        let legacy = sign_payload(SECRET, body);
        assert!(verify_signature_v1("wrong", body, &legacy).is_err());
    }
}

// ---------------------------------------------------------------------------
// Issue #1432: ClientIp extractor must ignore spoofed X-Forwarded-For from
// untrusted peers and honour it from trusted proxies.
// ---------------------------------------------------------------------------
mod client_ip_tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use soroban_pulse::middleware::client_ip::{resolve_client_ip, TrustedProxies};

    fn addr(a: u8, b: u8, c: u8, d: u8) -> SocketAddr {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(a, b, c, d)), 12345)
    }

    #[test]
    fn untrusted_peer_xff_is_ignored() {
        let trusted = TrustedProxies::from_cidrs(&["10.0.0.0/8"]).unwrap();
        let peer = addr(203, 0, 113, 7); // not a trusted proxy
        let xff = "1.2.3.4, 5.6.7.8";
        let ip = resolve_client_ip(peer, Some(xff), &trusted);
        assert_eq!(
            ip,
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 7)),
            "spoofed X-Forwarded-For from an untrusted peer must be ignored"
        );
    }

    #[test]
    fn trusted_proxy_xff_is_honoured_rightmost_untrusted_hop() {
        let trusted = TrustedProxies::from_cidrs(&["10.0.0.0/8"]).unwrap();
        let peer = addr(10, 0, 0, 5); // trusted proxy
        // Client -> proxy1 -> proxy2(peer). Right-most untrusted hop is 198.51.100.9.
        let xff = "198.51.100.9, 10.0.0.2";
        let ip = resolve_client_ip(peer, Some(xff), &trusted);
        assert_eq!(
            ip,
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 9)),
            "must take the right-most untrusted hop"
        );
    }

    #[test]
    fn trusted_proxy_without_xff_uses_peer() {
        let trusted = TrustedProxies::from_cidrs(&["10.0.0.0/8"]).unwrap();
        let peer = addr(10, 0, 0, 5);
        let ip = resolve_client_ip(peer, None, &trusted);
        assert_eq!(ip, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5)));
    }

    #[test]
    fn malformed_xff_from_trusted_proxy_falls_back_to_peer() {
        let trusted = TrustedProxies::from_cidrs(&["10.0.0.0/8"]).unwrap();
        let peer = addr(10, 0, 0, 5);
        let ip = resolve_client_ip(peer, Some("not-an-ip"), &trusted);
        assert_eq!(ip, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5)));
    }

    #[test]
    fn empty_trusted_proxies_never_trusts_xff() {
        let trusted = TrustedProxies::empty();
        let peer = addr(10, 0, 0, 5);
        let ip = resolve_client_ip(peer, Some("1.2.3.4"), &trusted);
        assert_eq!(ip, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5)));
    }
}