FROM quay.io/mhildenb/dev-demo-base:latest

USER root

# Update to more recent version of tekton for sake of VSCode extensions
RUN curl -L https://github.com/tektoncd/cli/releases/download/v0.13.1/tkn_0.13.1_Linux_x86_64.tar.gz | \
    tar -xvzf - -C /usr/local/bin/ tkn && chmod 755 /usr/local/bin/tkn
    
USER jboss

# this is done in the base image already (to support the demo shell images too), but for those that make
# local changes to .zshrc they should not have to rebuild the base
COPY .zshrc.example $HOME/.zshrc