SHELL = /bin/bash

BUCKET ?= gresik
BUCKET_REGION ?= us-east-1
STACK_NAME ?= appmesh-sample
STACK_REGION ?= us-east-2
S3_PREFIX = templates/
EC2_KEY_NAME ?= rmaulan-testbed
ALLOW_SSH_FROM_CIDR ?= 0.0.0.0/0



.PHONY: validate
validate:
	cfn-lint infrastructure/*.yaml -i W2001
	cfn-lint -i W2001 -t main.yaml

.PHONY: upload
upload: validate
	aws s3 sync infrastructure s3://$(BUCKET)/$(STACK_NAME)/$(S3_PREFIX) --region $(BUCKET_REGION)

.PHONY: deploy
deploy: upload
	aws cloudformation deploy \
		--template-file main.yaml \
		--stack-name $(STACK_NAME) \
		--region $(STACK_REGION) \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
		--parameter-overrides \
				ClusterName=$(STACK_NAME) \
				BucketName=$(BUCKET) \
				BucketRegion=$(BUCKET_REGION) \
				S3PrefixNameParameter=$(S3_PREFIX) \
				KeyName=$(EC2_KEY_NAME) \
				AllowSSHFrom=$(ALLOW_SSH_FROM_CIDR)
