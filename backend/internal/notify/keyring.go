// Package notify is the transactional email outbox of TRD 01 sections 6.7, 8.2 and 8.3:
// encrypted payloads enqueued inside the caller's transaction, a leased worker with a bounded
// send budget, templates, and Sender implementations (fake for tests, SMTP for Mailpit).
//
// Secrets never leave this package in readable form: errors and log lines carry row ids and
// error classes only, never key material, OTP codes or decrypted payloads.
package notify

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"io"

	"github.com/google/uuid"
)

// KeyBytes is the AES-256 key length.
const KeyBytes = 32

// Key is one outbox encryption key with the id stored next to each ciphertext
// (email_outbox.payload_key_id), so keys can rotate.
type Key struct {
	ID  int16
	Key []byte
}

// Errors from the keyring. They never include key material, plaintext or ciphertext.
var (
	ErrUnknownKey = errors.New("notify: payload key id is not configured")
	ErrDecrypt    = errors.New("notify: payload cannot be decrypted")
)

// Keyring seals and opens outbox payloads with AES-256-GCM. The first key is current and is
// used for every new payload. The others only open old rows, which lets a rotation drain.
type Keyring struct {
	current int16
	aeads   map[int16]cipher.AEAD
	rand    io.Reader
}

// NewKeyring builds a keyring, current key first. Ids must be positive and unique, keys exactly
// KeyBytes long.
func NewKeyring(keys ...Key) (*Keyring, error) {
	if len(keys) == 0 {
		return nil, errors.New("notify: at least one outbox key is required")
	}
	k := &Keyring{current: keys[0].ID, aeads: make(map[int16]cipher.AEAD, len(keys)), rand: rand.Reader}
	for i, key := range keys {
		if key.ID < 1 {
			return nil, fmt.Errorf("notify: outbox key %d has id %d, ids must be 1 or more", i+1, key.ID)
		}
		if _, dup := k.aeads[key.ID]; dup {
			return nil, fmt.Errorf("notify: outbox key id %d is used twice", key.ID)
		}
		if len(key.Key) != KeyBytes {
			return nil, fmt.Errorf("notify: outbox key id %d must be exactly %d bytes", key.ID, KeyBytes)
		}
		block, err := aes.NewCipher(append([]byte(nil), key.Key...))
		if err != nil {
			return nil, fmt.Errorf("notify: outbox key id %d: invalid key", key.ID)
		}
		aead, err := cipher.NewGCM(block)
		if err != nil {
			return nil, fmt.Errorf("notify: outbox key id %d: invalid key", key.ID)
		}
		k.aeads[key.ID] = aead
	}
	return k, nil
}

// CurrentID is the key id new payloads are sealed with.
func (k *Keyring) CurrentID() int16 { return k.current }

// Seal encrypts plaintext for the outbox row rowID with the current key. The row id is the
// associated data, so a ciphertext copied into another row no longer opens (TRD 8.2). The
// result is nonce || ciphertext || tag.
func (k *Keyring) Seal(rowID uuid.UUID, plaintext []byte) ([]byte, int16, error) {
	aead := k.aeads[k.current]
	nonce := make([]byte, aead.NonceSize(), aead.NonceSize()+len(plaintext)+aead.Overhead())
	if _, err := io.ReadFull(k.rand, nonce); err != nil {
		return nil, 0, errors.New("notify: read randomness for nonce")
	}
	return aead.Seal(nonce, nonce, plaintext, rowID[:]), k.current, nil
}

// SealAD encrypts plaintext with the current key and explicit associated data, for artifacts
// that bind more than a row id (TRD 05 §11.1 export chunks). The result is nonce || ciphertext
// || tag, 28 bytes longer than plaintext.
func (k *Keyring) SealAD(ad, plaintext []byte) ([]byte, int16, error) {
	aead := k.aeads[k.current]
	nonce := make([]byte, aead.NonceSize(), aead.NonceSize()+len(plaintext)+aead.Overhead())
	if _, err := io.ReadFull(k.rand, nonce); err != nil {
		return nil, 0, errors.New("notify: read randomness for nonce")
	}
	return aead.Seal(nonce, nonce, plaintext, ad), k.current, nil
}

// OpenAD decrypts a payload sealed by SealAD with the same associated data.
func (k *Keyring) OpenAD(keyID int16, ad, sealed []byte) ([]byte, error) {
	aead, ok := k.aeads[keyID]
	if !ok {
		return nil, ErrUnknownKey
	}
	if len(sealed) < aead.NonceSize()+aead.Overhead() {
		return nil, ErrDecrypt
	}
	plain, err := aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], ad)
	if err != nil {
		return nil, ErrDecrypt
	}
	return plain, nil
}

// Open decrypts a payload sealed for rowID with keyID.
func (k *Keyring) Open(rowID uuid.UUID, keyID int16, sealed []byte) ([]byte, error) {
	aead, ok := k.aeads[keyID]
	if !ok {
		return nil, ErrUnknownKey
	}
	if len(sealed) < aead.NonceSize()+aead.Overhead() {
		return nil, ErrDecrypt
	}
	nonce, body := sealed[:aead.NonceSize()], sealed[aead.NonceSize():]
	plain, err := aead.Open(nil, nonce, body, rowID[:])
	if err != nil {
		return nil, ErrDecrypt
	}
	return plain, nil
}
