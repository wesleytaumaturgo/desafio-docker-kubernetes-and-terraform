{{/*
Labels comuns. Uso: include "mural.labels" (dict "ctx" $ "component" "api")
*/}}
{{- define "mural.labels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Seletor estável (subconjunto imutável das labels).
*/}}
{{- define "mural.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/*
DATABASE_URL a partir de values; a senha é validada no secret.yaml (required).
*/}}
{{- define "mural.databaseUrl" -}}
postgres://{{ .Values.db.user }}:{{ .Values.db.password }}@postgres:5432/{{ .Values.db.name }}?sslmode=disable
{{- end -}}
