{{- define "hypershift.cpvacWorkload" -}}
{{- /* One base-profile workload entry. Args: workload (from values), defaultMaxAllowed.
Every workload names its main container with a maxAllowed, so VPA can't size it
past the largest node; HyperShift doesn't autoscale containers no profile names. */ -}}
- resource: {{ .workload.resource | default "deployments" }}
  name: {{ .workload.name }}
  resourcePolicy:
    containerPolicies:
      - containerName: {{ .workload.container | default .workload.name }}
        {{- with .workload.minAllowed }}
        minAllowed:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        maxAllowed:
          {{- toYaml (.workload.maxAllowed | default .defaultMaxAllowed) | nindent 10 }}
{{- end }}
