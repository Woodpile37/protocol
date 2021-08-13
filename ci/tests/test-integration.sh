#!/bin/bash

cat << EOF
  test-integration:
    machine:
      image: ubuntu-2004:202010-01
    working_directory: ~/protocol
    steps:
      - restore_cache:
          key: protocol-completed-build-{{ .Environment.CIRCLE_SHA1 }}
      - run:
          name: Install dependencies
          command: |
            sudo apt update
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
            export NVM_DIR="/opt/circleci/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
            [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
            nvm install v15.10.0
            sudo apt install npm
            npm install --global yarn
      - run:
          name: Run integration tests
          command: |
            node -v
            npm -v
            yarn -v
            yarn optimism-up
            sleep 60
            yarn --cwd packages/core test-e2e
EOF