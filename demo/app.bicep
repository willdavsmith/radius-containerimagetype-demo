extension radius
extension containerImages
extension containers
extension secrets

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('GitHub username for GHCR authentication.')
param ghcrUsername string

@secure()
@description('GitHub PAT with write:packages scope for GHCR authentication.')
param ghcrPassword string

@description('The full container image reference to build and push. Must be lowercase.')
param image string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
  }
}

// Store GHCR credentials as a Radius secret (creates a K8s Secret).
// The secrets recipe base64-encodes string values into K8s secret .data.
// Using encoding: 'base64' puts the value directly into binary_data, which
// K8s mounts as raw bytes — exactly what BuildKit expects for config.json.
var dockerConfigJson = '{"auths":{"ghcr.io":{"username":"${ghcrUsername}","password":"${ghcrPassword}"}}}'

resource ghcrCredentials 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-credentials'
  properties: {
    environment: environment
    application: app.id
    kind: 'generic'
    data: {
      '.dockerconfigjson': {
        encoding: 'base64'
        value: base64(dockerConfigJson)
      }
    }
  }
}

// Build and push the container image from local source to ghcr.io.
// The build context is a hostPath on the kind node (mounted via extraMounts).
resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    image: image
    build: {
      context: '/app/demo'
    }
    registry: {
      secretName: ghcrCredentials.name
    }
  }
}

// Deploy a container using the image built above.
resource demo 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: demoImage.properties.image
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      demoContainerImage: {
        source: demoImage.id
      }
    }
  }
}
