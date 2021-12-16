default: debug

debug:
	ansible-playbook nvidia.cumulus.debug

ee:
	cd ansible-ee && ansible-builder build --tag networkop/ansible-ee --container-runtime docker
	docker push networkop/ansible-ee


release: 
	git add .
	git commit -m "$$(date)"
	git push

retry:
	git add .
	git commit --amend --no-edit
	git push --force