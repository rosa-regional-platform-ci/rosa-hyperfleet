{{/*
Recommender Deployment and lease names. The "default" recommender keeps the
upstream names; every other recommender is suffixed with its name.
*/}}
{{- define "vpa.recommenderName" -}}
{{- if eq .name "default" -}}vpa-recommender{{- else -}}vpa-recommender-{{ .name }}{{- end -}}
{{- end -}}

{{- define "vpa.recommenderLease" -}}
{{- include "vpa.recommenderName" . }}-lease
{{- end -}}

{{/*
Pod spec fields shared by every VPA component.
*/}}
{{- define "vpa.podCommon" -}}
imagePullSecrets:
  - name: pull-secret
priorityClassName: {{ .Values.vpa.priorityClassName }}
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "vpa.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
Spread a component's replicas across zones and hosts. Takes the app label value.
*/}}
{{- define "vpa.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: {{ . }}
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: {{ . }}
{{- end -}}

{{- define "vpa.probes" -}}
livenessProbe:
  httpGet:
    path: /health-check
    port: prometheus
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health-check
    port: prometheus
  periodSeconds: 10
  failureThreshold: 3
{{- end -}}

{{- define "vpa.leaderElectionArgs" -}}
- --leader-elect=true
- --leader-elect-resource-namespace={{ .namespace }}
- --leader-elect-resource-name={{ .lease }}
{{- end -}}
