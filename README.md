# Cloud Native Days France Platform

This repository contains the GitOps configuration for the Cloud Native Days France platform. The platform is designed to host and orchestrate tools for organizing the event, with a modular structure for different domains:

- 📢 **callforpapers**: Contains manifests for the Pretalx CFP platform
- 🎫 **ticketing**: Infrastructure for ticket sales and attendee management (e.g., Alf.io)
- 📆 **project**: Project management and coordination tools (e.g., OpenProject)
- 💬 **communication**: Services for event communication (e.g., Mattermost)
- **operators**: Contains HelmRelease and Kustomization manifests for deploying operators.
- **namespaces**: Namespace definitions for all platform domains.
- **flux**: FluxCD sources and Kustomizations for GitOps automation.

Each directory contains Flux manifests and configuration for its respective domain.

♥️ These apps are hosted by [Enix](https://enix.io).
The Kubernetes cluster comes with pre-installed components such as the CloudNativePG and cert-manager operators, as well as other required features like storage, ingress, and monitoring.
