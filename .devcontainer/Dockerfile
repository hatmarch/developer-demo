FROM quay.io/mhildenb/dev-demo-base:1.1

USER root

# Update to more recent version of tekton for sake of VSCode extensions
RUN curl -L https://github.com/tektoncd/cli/releases/download/v0.12.1/tkn_0.12.1_Linux_x86_64.tar.gz | \
    tar -xvzf - -C /usr/local/bin/ tkn && chmod 755 /usr/local/bin/tkn
    
USER jboss