{{/*
=====================================================================
File        : charts/tasktracker/templates/_helpers.tpl
Assignment  : DSO202 Assignment 4 (from Assignment 3)
Descriptor  : Unit III 3.2 - named templates
Purpose     : Shared labels, image reference and environment rendering, so
              that each tier's template stays short and identical in shape.
=====================================================================
*/}}

{{/* tasktracker.environment: required, so nothing renders without one. */}}
{{- define "tasktracker.environment" -}}
{{- required "environment must be set by environments/<env>/values.yaml" .Values.environment -}}
{{- end }}

{{/* tasktracker.chart: "<name>-<version>" for the helm.sh/chart label. */}}
{{- define "tasktracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* tasktracker.selectorLabels: stable labels; takes a dict with "tier". */}}
{{- define "tasktracker.selectorLabels" -}}
app: task-tracker
tier: {{ .tier }}
{{- end }}

{{/* tasktracker.labels: full label set; takes a dict with "root" and "tier". */}}
{{- define "tasktracker.labels" -}}
helm.sh/chart: {{ include "tasktracker.chart" .root }}
{{ include "tasktracker.selectorLabels" . }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
dso202/assignment: "04"
dso202/environment: {{ include "tasktracker.environment" .root | quote }}
{{- end }}

{{/*
tasktracker.image (C1): "<repository>:<tag>" from a tier's image values.
No tag is ever written in a template, so a release is a values change.
*/}}
{{- define "tasktracker.image" -}}
{{- printf "%s:%s" (required "image.repository is required" .repository) (required "image.tag is required" (toString .tag)) -}}
{{- end }}

{{/*
tasktracker.extraEnv (C2): renders a tier's 'env' map as container env
entries, sorted by name so the output is stable between renders.
*/}}
{{- define "tasktracker.extraEnv" -}}
{{- range $name := keys . | sortAlpha }}
- name: {{ $name }}
  value: {{ index $ $name | toString | quote }}
{{- end }}
{{- end }}
