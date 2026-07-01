{{/*
Expand the name of the chart.
*/}}
{{- define "midnight.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "midnight.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version as used by the chart label.
*/}}
{{- define "midnight.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource. Pass a "component" via the dict, e.g.
  {{- include "midnight.labels" (dict "ctx" . "component" "cardano-node") }}
*/}}
{{- define "midnight.labels" -}}
helm.sh/chart: {{ include "midnight.chart" .ctx }}
app.kubernetes.io/part-of: {{ include "midnight.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/component: {{ .component }}
app: {{ .component }}
{{- end }}

{{/*
Selector labels (stable across upgrades). The literal "app" key preserves the
in-stack service DNS/selectors used by the original k3s manifests.
*/}}
{{- define "midnight.selectorLabels" -}}
app: {{ .component }}
{{- end }}

{{/*
Render imagePullSecrets if any are configured.
*/}}
{{- define "midnight.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
