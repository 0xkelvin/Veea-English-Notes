package httpapi

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
)

// TRD 05 vocabulary sync. Every route is bearer-authenticated through authenticated.

// query returns the request's query parameters, refusing unknown or repeated keys.
func query(r *http.Request, allowed ...string) (url.Values, bool) {
	if r.URL.ForceQuery && r.URL.RawQuery == "" {
		return nil, false
	}
	v, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return nil, false
	}
	for k, vs := range v {
		ok := false
		for _, a := range allowed {
			ok = ok || k == a
		}
		if !ok || len(vs) != 1 {
			return nil, false
		}
	}
	return v, true
}

func pageLimit(v url.Values) (int, bool) {
	s, set := v["limit"]
	if !set {
		return learning.MaxPageChanges, true
	}
	n, err := strconv.Atoi(s[0])
	return n, err == nil && n >= 1 && n <= learning.MaxPageChanges && s[0] == strconv.Itoa(n)
}

func (h *Handlers) learningState(w http.ResponseWriter, r *http.Request, p session.Principal) {
	v, ok := query(r, "writer_id")
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var writer *uuid.UUID
	if s, set := v["writer_id"]; set {
		id, err := uuid.Parse(s[0])
		if err != nil || len(s[0]) != 36 {
			h.fail(w, r, httpx.ErrBadRequest)
			return
		}
		writer = &id
	}
	out, err := h.Learning.State(r.Context(), p, writer)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (h *Handlers) learningRegisterWriter(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct{}
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		h.fail(w, r, err)
		return
	}
	out, err := h.Learning.RegisterWriter(r.Context(), p)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, out)
}

func (h *Handlers) learningPush(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		Epoch     uuid.UUID         `json:"epoch"`
		WriterID  uuid.UUID         `json:"writer_id"`
		Mutations []json.RawMessage `json:"mutations"`
	}
	if err := httpx.DecodeJSONLimit(w, r, &req, learning.MaxRequestBytes); err != nil {
		h.fail(w, r, err)
		return
	}
	h.push(w, r, p, learning.PushInput{Epoch: req.Epoch, WriterID: req.WriterID}, req.Mutations)
}

func (h *Handlers) learningImport(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	var req struct {
		Epoch         uuid.UUID         `json:"epoch"`
		WriterID      uuid.UUID         `json:"writer_id"`
		CapacityBasis learning.Basis    `json:"capacity_basis"`
		Mutations     []json.RawMessage `json:"mutations"`
	}
	if err := httpx.DecodeJSONLimit(w, r, &req, learning.MaxRequestBytes); err != nil {
		h.fail(w, r, err)
		return
	}
	basis := req.CapacityBasis
	h.push(w, r, p, learning.PushInput{Epoch: req.Epoch, WriterID: req.WriterID, Import: &basis}, req.Mutations)
}

func (h *Handlers) push(w http.ResponseWriter, r *http.Request, p session.Principal, in learning.PushInput, raw []json.RawMessage) {
	if in.Epoch == uuid.Nil || in.WriterID == uuid.Nil {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	ms, err := learning.DecodeMutations(raw)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	in.Mutations = ms
	out, err := h.Learning.Push(r.Context(), p, in)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (h *Handlers) learningChanges(w http.ResponseWriter, r *http.Request, p session.Principal) {
	v, ok := query(r, "cursor", "limit")
	limit, lok := pageLimit(v)
	if !ok || !lok || len(v["cursor"]) != 1 {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	out, err := h.Learning.Changes(r.Context(), p, v["cursor"][0], limit)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (h *Handlers) learningSnapshot(w http.ResponseWriter, r *http.Request, p session.Principal) {
	v, ok := query(r, "page_token", "limit")
	limit, lok := pageLimit(v)
	token := ""
	if t, set := v["page_token"]; set {
		token = t[0]
		ok = ok && token != ""
	}
	if !ok || !lok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	out, err := h.Learning.Snapshot(r.Context(), p, token, limit)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}
