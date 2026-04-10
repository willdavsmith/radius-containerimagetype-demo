// NOTE: This recipe doesn't work properly yet. It doesn't wait until the container is pushed
// before returning as "Completed". This may be a bug in dynamic-rp or a limitation for the Bicep
// Kubernetes provider.

@description('Radius context object passed into the recipe.')
param context object

extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

// ── Resource properties ──────────────────────────────────────────────
var resourceName = context.resource.name
var namespace = context.runtime.kubernetes.namespace
var normalizedName = resourceName

var resourceProperties = context.resource.properties ?? {}
var image = resourceProperties.image
var buildContext = resourceProperties.build.context
var dockerfile = resourceProperties.build.?dockerfile ?? 'Dockerfile'
var registrySecretName = resourceProperties.registry.secretName

// ── Labels ───────────────────────────────────────────────────────────
var environmentSegments = context.resource.properties.environment != null ? split(string(context.resource.properties.environment), '/') : []
var environmentLabel = length(environmentSegments) > 0 ? last(environmentSegments) : ''

var labels = {
  'radapp.io/resource': resourceName
  'radapp.io/environment': environmentLabel
  'radapp.io/application': context.application == null ? '' : context.application.name
}

// ── Build Job ────────────────────────────────────────────────────────
// Mounts the source directory from the host via hostPath, then BuildKit
// builds and pushes the image to the remote registry (e.g., ghcr.io).
resource buildJob 'batch/Job@v1' = {
  metadata: {
    name: '${normalizedName}-build'
    namespace: namespace
    labels: labels
  }
  spec: {
    backoffLimit: 3
    ttlSecondsAfterFinished: 600
    template: {
      metadata: {
        labels: labels
      }
      spec: {
        restartPolicy: 'Never'

        containers: [
          {
            name: 'build-and-push'
            image: 'moby/buildkit:latest'
            command: [
              'buildctl-daemonless.sh'
              'build'
              '--frontend=dockerfile.v0'
              '--local=context=/workspace'
              '--local=dockerfile=/workspace'
              '--opt=filename=${dockerfile}'
              '--output=type=image,name=${image},push=true'
            ]
            volumeMounts: [
              {
                name: 'source'
                mountPath: '/workspace'
                readOnly: true
              }
              {
                name: 'docker-config'
                mountPath: '/root/.docker'
                readOnly: true
              }
            ]
            securityContext: {
              privileged: true
            }
          }
        ]

        volumes: [
          {
            name: 'source'
            hostPath: {
              path: buildContext
              type: 'Directory'
            }
          }
          {
            name: 'docker-config'
            secret: {
              secretName: registrySecretName
              items: [
                {
                  key: '.dockerconfigjson'
                  path: 'config.json'
                }
              ]
            }
          }
        ]
      }
    }
  }
}

// ── Outputs ──────────────────────────────────────────────────────────
var jobResource = '/planes/kubernetes/local/namespaces/${namespace}/providers/batch/Job/${normalizedName}-build'

output result object = {
  resources: [jobResource]
}
