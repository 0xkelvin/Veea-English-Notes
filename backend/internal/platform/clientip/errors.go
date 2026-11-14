package clientip

import "errors"

// errInvalidProxy never echoes the offending text, so a misconfigured value is not logged back.
var errInvalidProxy = errors.New("clientip: invalid trusted proxy entry, expected an IP address or CIDR")
