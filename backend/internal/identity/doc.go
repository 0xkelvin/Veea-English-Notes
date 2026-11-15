// Package identity holds the account identity primitives of TRD 01: email
// normalization, the password policy with its blocklist, and Argon2id hashing.
//
// Nothing here talks to the database. In particular the Hasher takes no
// transaction, connection or pool: callers hash and verify before they open a
// transaction and pass only the resulting string into it (TRD 7.1 rule 4).
package identity
