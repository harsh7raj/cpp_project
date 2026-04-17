{{/*
Chart name / fullname helpers
*/}}
{{- define "jenkins-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "jenkins-ha.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "jenkins-ha.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels applied to every resource.
*/}}
{{- define "jenkins-ha.labels" -}}
app: jenkins
app.kubernetes.io/name: {{ include "jenkins-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Selector labels — stable across upgrades.
*/}}
{{- define "jenkins-ha.selectorLabels" -}}
app: jenkins
{{- end -}}

{{/*
ServiceAccount name
*/}}
{{- define "jenkins-ha.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default "jenkins-ha-sa" -}}
{{- end -}}

{{/*
Image pull secret name — used in both the generated Secret and the StatefulSet.
*/}}
{{- define "jenkins-ha.pullSecretName" -}}
{{- if .Values.imagePullSecret.existingSecret -}}
{{- .Values.imagePullSecret.existingSecret -}}
{{- else -}}
{{- .Values.imagePullSecret.name -}}
{{- end -}}
{{- end -}}

{{/*
Render `imagePullSecrets:` block when enabled.
*/}}
{{- define "jenkins-ha.imagePullSecrets" -}}
{{- if .Values.imagePullSecret.enabled }}
imagePullSecrets:
  - name: {{ include "jenkins-ha.pullSecretName" . }}
{{- end }}
{{- end -}}
