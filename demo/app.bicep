extension radius
extension containerImages
extension containers

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Tag for the produced image. Required because the build context is a remote git URL.')
param imageTag string

@description('Git URL the recipe clones inside the cluster to build from.')
param buildContext string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
  }
}

// Build and push the container image. Registry credentials are owned
// by the platform engineer (a dockerconfigjson Secret in radius-system,
// referenced by the recipe's `registrySecretName` parameter at
// registration time) and never appear in this developer Bicep. The
// recipe materializes a per-resource pull Secret in the application
// namespace and exposes its name via `imagePullSecretName`.
resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    tag: imageTag
    build: {
      context: buildContext
    }
  }
}

// Deploy a container using the image built above. `imagePullSecrets`
// references the Secret the recipe created in this namespace; kubelet
// uses it to pull from the same registry the recipe pushed to.
resource demo 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
    application: app.id
    imagePullSecrets: [demoImage.properties.imagePullSecretName]
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
