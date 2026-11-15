package httpapi

import (
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/google/uuid"
	"net/http"
	"strconv"
)

func (h *Handlers) cartridgeCatalog(w http.ResponseWriter, r *http.Request, p session.Principal) {
	if _, ok := query(r); !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	rows, err := h.Learning.CartridgeCatalog(r.Context(), p)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"cartridges": rows})
}
func cartridgePath(r *http.Request) (string, int32, bool) {
	id := r.PathValue("cartridge_id")
	version := r.PathValue("version")
	n, err := strconv.ParseInt(version, 10, 32)
	_, ok := query(r)
	return id, int32(n), ok && err == nil && n > 0 && strconv.FormatInt(n, 10) == version && learning.ValidCartridgeID(id)
}
func (h *Handlers) cartridgeContent(w http.ResponseWriter, r *http.Request, p session.Principal) {
	id, v, ok := cartridgePath(r)
	if !ok {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	body, err := h.Learning.CartridgeContent(r.Context(), p, id, v)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	_, _ = w.Write(body)
}
func (h *Handlers) cartridgeInstall(w http.ResponseWriter, r *http.Request, p session.Principal) {
	var req struct {
		Epoch         uuid.UUID       `json:"epoch"`
		CapacityBasis *learning.Basis `json:"capacity_basis"`
	}
	if err := httpx.DecodeJSONLimit(w, r, &req, httpx.MaxBodyBytes); err != nil {
		h.fail(w, r, err)
		return
	}
	id, v, ok := cartridgePath(r)
	if !ok || req.Epoch == uuid.Nil || req.CapacityBasis == nil || req.CapacityBasis.LiveWords < 0 || req.CapacityBasis.ContentBytes < 0 {
		h.fail(w, r, httpx.ErrBadRequest)
		return
	}
	out, err := h.Learning.InstallCartridge(r.Context(), p, id, v, learning.CartridgeInstallInput{Epoch: req.Epoch, CapacityBasis: *req.CapacityBasis})
	if err != nil {
		h.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, 200, out)
}
