{{/* Labels on every resource. */}}
{{- define "thumbnail.labels" -}}
app.kubernetes.io/name: thumbnail
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Selector labels for one component: (dict "root" $ "component" "api"). */}}
{{- define "thumbnail.selectorLabels" -}}
app.kubernetes.io/name: thumbnail
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "thumbnail.image" -}}
{{ .Values.image.repository }}:{{ required "image.tag is required (make deploy sets it)" .Values.image.tag }}
{{- end }}

{{/* Connection settings shared by the app containers and the init check. */}}
{{- define "thumbnail.connectionEnv" -}}
- name: MONGO_URL
  valueFrom:
    secretKeyRef: { name: {{ .Values.mongodb.secretName }}, key: {{ .Values.mongodb.urlKey }} }
- name: MINIO_ENDPOINT
  value: {{ .Values.minio.endpoint | quote }}
- name: MINIO_PORT
  value: {{ .Values.minio.port | quote }}
- name: MINIO_USE_SSL
  value: {{ .Values.minio.useSSL | quote }}
- name: MINIO_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ .Values.minio.secretName }}, key: {{ .Values.minio.accessKeyKey }} }
- name: MINIO_SECRET_KEY
  valueFrom:
    secretKeyRef: { name: {{ .Values.minio.secretName }}, key: {{ .Values.minio.secretKeyKey }} }
{{- end }}

{{/*
OpenTelemetry settings: (dict "root" $ "service" "thumbnail-api" "traces" true).
The sampler drops every trace that doesn't come in through the gateway
(probes, scrapes, startup), because Envoy starts and samples the traces.
*/}}
{{- define "thumbnail.otelEnv" -}}
{{- if .root.Values.otel.enabled }}
- name: POD_NAME
  valueFrom: { fieldRef: { fieldPath: metadata.name } }
- name: POD_NAMESPACE
  valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
- name: NODE_OPTIONS
  value: --require /otel-auto-instrumentation-nodejs/autoinstrumentation.js
- name: OTEL_SERVICE_NAME
  value: {{ .service }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: service.version={{ .root.Values.image.tag }},k8s.namespace.name=$(POD_NAMESPACE),k8s.pod.name=$(POD_NAME)
- name: OTEL_TRACES_EXPORTER
  value: {{ ternary "otlp" "none" .traces }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .root.Values.otel.tracesEndpoint }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: http/protobuf
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0"
- name: OTEL_METRICS_EXPORTER
  value: prometheus
- name: OTEL_EXPORTER_PROMETHEUS_HOST
  value: 0.0.0.0
- name: OTEL_LOGS_EXPORTER
  value: none
- name: OTEL_SEMCONV_STABILITY_OPT_IN
  value: http
- name: OTEL_NODE_DISABLED_INSTRUMENTATIONS
  value: dns,net,fs
- name: OTEL_NODE_RESOURCE_DETECTORS
  value: env,host,os,process,container
{{- end }}
{{- end }}

{{/* Init containers shared by the API and the worker. */}}
{{- define "thumbnail.initContainers" -}}
- name: wait-for-deps
  image: {{ include "thumbnail.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: ["node", "/scripts/wait-for-deps.js"]
  env:
    {{- include "thumbnail.connectionEnv" . | nindent 4 }}
    - name: NODE_PATH
      value: /usr/src/app/node_modules
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits: { memory: 128Mi }
  securityContext:
    {{- include "thumbnail.containerSecurityContext" . | nindent 4 }}
  volumeMounts:
    - name: scripts
      mountPath: /scripts
{{- if .Values.otel.enabled }}
- name: otel-auto-instrumentation
  image: {{ .Values.otel.image }}
  command: ["cp", "-r", "/autoinstrumentation/.", "/otel-auto-instrumentation-nodejs"]
  # The copy is 133 MB (19k files) and its page cache counts against the
  # limit: 64Mi got OOM-killed. Only held for the few seconds of the copy.
  resources:
    requests: { cpu: 10m, memory: 64Mi }
    limits: { memory: 256Mi }
  securityContext:
    {{- include "thumbnail.containerSecurityContext" . | nindent 4 }}
  volumeMounts:
    - name: otel-auto-instrumentation
      mountPath: /otel-auto-instrumentation-nodejs
{{- end }}
{{- end }}

{{- define "thumbnail.volumes" -}}
- name: scripts
  configMap:
    name: {{ .Release.Name }}-scripts
- name: tmp
  emptyDir: {}
{{- if .Values.otel.enabled }}
- name: otel-auto-instrumentation
  emptyDir: {}
{{- end }}
{{- end }}

{{- define "thumbnail.appVolumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- if .Values.otel.enabled }}
- name: otel-auto-instrumentation
  mountPath: /otel-auto-instrumentation-nodejs
{{- end }}
{{- end }}

{{/* Restricted Pod Security standard. The image has a `node` user (uid 1000). */}}
{{- define "thumbnail.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "thumbnail.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{/*
Spread replicas over nodes when possible, without blocking scheduling.
pod-template-hash: count only pods of the same revision, otherwise a rolling
update balances new pods against old ones and can stack them on one node.
Honor: tainted nodes (the kind control plane) don't count as empty domains.
*/}}
{{- define "thumbnail.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    nodeTaintsPolicy: Honor
    matchLabelKeys: [pod-template-hash]
    labelSelector:
      matchLabels:
        {{- include "thumbnail.selectorLabels" . | nindent 8 }}
{{- end }}
