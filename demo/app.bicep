extension radius
extension containerImages
extension containers
extension secrets

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Tag for the produced image. Required because the build context is a remote git URL.')
param imageTag string

@description('Git URL the recipe clones inside the cluster to build from.')
param buildContext string

@description('Username for authenticating to the registry the recipe pushes to.')
param registryUsername string

@description('Password (or PAT) for authenticating to the registry the recipe pushes to.')
@secure()
param registryPassword string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
  }
}

// Registry credentials. Realized by Radius as a Kubernetes Secret in
// the application's namespace; the containerImages recipe reads
// `USERNAME` and `PASSWORD` from it to authenticate to the registry.
resource registryCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'registry-creds'
  properties: {
    environment: environment
    application: app.id
    data: {
      USERNAME: {
        value: registryUsername
      }
      PASSWORD: {
        value: registryPassword
      }
    }
  }
}

// Build and push the container image. The recipe (registered with a
// `registry` parameter pointing at this repo's GHCR) clones from
// `buildContext` inside the cluster on its rootless BuildKit sidecar
// and pushes to `<registry>/<this-resource-name>:<imageTag>`.
resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    secretName: registryCreds.name
    tag: imageTag
    build: {
      context: buildContext
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
