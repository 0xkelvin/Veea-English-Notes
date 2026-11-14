package notify

import (
	"bytes"
	"errors"
	htmltemplate "html/template"
	texttemplate "text/template"
	"time"
)

// CodeLifetimeText is the code lifetime stated in code emails (TRD 4.2: 10 minutes).
const CodeLifetimeText = "10 minutes"

// Rendered is a ready-to-send email body.
type Rendered struct {
	Subject string
	Text    string
	HTML    string
}

type templateSpec struct {
	subject string
	intro   string
}

// Copy is English only in Phase 1 (Product Doc 5.7). Code emails contain no links, so a stolen
// email can never sign anyone in (TRD 8.3).
var specs = map[Template]templateSpec{
	TemplateSignupCode:      {"Your Veea sign-up code", "Use this code to finish creating your Veea English Notes account."},
	TemplateLoginCode:       {"Your Veea sign-in code", "Use this code to sign in to Veea English Notes."},
	TemplateResetCode:       {"Your Veea password reset code", "Use this code to reset your Veea English Notes password."},
	TemplateSetPasswordCode: {"Your Veea code to add a password", "Use this code to add a password to your Veea English Notes account."},
	TemplatePasswordAdded:   {"A password was added to your Veea account", "A password was added to your Veea English Notes account."},
	TemplatePasswordChanged: {"Your Veea password was changed", "The password of your Veea English Notes account was changed."},
	TemplatePasswordReset:   {"Your Veea password was reset", "The password of your Veea English Notes account was reset."},
}

type view struct {
	Intro      string
	Code       string
	Lifetime   string
	DeviceName string
	When       string
}

var textCode = texttemplate.Must(texttemplate.New("code").Parse(`{{.Intro}}

Your code: {{.Code}}

It expires in {{.Lifetime}}. If this wasn't you, ignore this email.
`))

var textNotice = texttemplate.Must(texttemplate.New("notice").Parse(`{{.Intro}}

When: {{.When}}
Device: {{.DeviceName}}

If this wasn't you, reset your password.
`))

var htmlCode = htmltemplate.Must(htmltemplate.New("code").Parse(`<!doctype html>
<html><body>
<p>{{.Intro}}</p>
<p style="font-size:24px;font-weight:bold;letter-spacing:4px">{{.Code}}</p>
<p>It expires in {{.Lifetime}}. If this wasn't you, ignore this email.</p>
</body></html>
`))

var htmlNotice = htmltemplate.Must(htmltemplate.New("notice").Parse(`<!doctype html>
<html><body>
<p>{{.Intro}}</p>
<p>When: {{.When}}<br>Device: {{.DeviceName}}</p>
<p>If this wasn't you, reset your password.</p>
</body></html>
`))

// Render builds the email for template t and payload p.
func Render(t Template, p Payload) (Rendered, error) {
	spec, ok := specs[t]
	if !ok {
		return Rendered{}, errors.New("notify: unknown template")
	}
	v := view{Intro: spec.intro, Lifetime: CodeLifetimeText}
	textT, htmlT := textNotice, htmlNotice
	if t.IsCode() {
		if !validCode(p.Code) {
			return Rendered{}, errors.New("notify: payload has no valid code")
		}
		v.Code = p.Code
		textT, htmlT = textCode, htmlCode
	} else {
		if p.OccurredAt.IsZero() || p.DeviceName == "" {
			return Rendered{}, errors.New("notify: notification payload is incomplete")
		}
		v.DeviceName = p.DeviceName
		v.When = p.OccurredAt.UTC().Format(time.RFC1123)
	}
	var tb, hb bytes.Buffer
	if err := textT.Execute(&tb, v); err != nil {
		return Rendered{}, errors.New("notify: render text body")
	}
	if err := htmlT.Execute(&hb, v); err != nil {
		return Rendered{}, errors.New("notify: render html body")
	}
	return Rendered{Subject: spec.subject, Text: tb.String(), HTML: hb.String()}, nil
}
