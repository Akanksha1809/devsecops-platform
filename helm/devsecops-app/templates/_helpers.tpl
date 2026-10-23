{{- define "devsecops-app.name" -}}
{{- .Values.nameOverride | default .Chart.Name -}}
{{- end -}}

{{- define "devsecops-app.labels" -}}
app.kubernetes.io/name: {{ include "devsecops-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.app.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "devsecops-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devsecops-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "devsecops-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- include "devsecops-app.name" . -}}
{{- end -}}
{{- end -}}
