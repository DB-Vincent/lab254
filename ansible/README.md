# Ansible

This is the location of the Ansible playbooks. 

## Dependencies

| Name          | Installation                                      |
|---------------|---------------------------------------------------|
| ansible.posix | `ansible-galaxy collection install ansible.posix` |

## template-machine.yaml

This Ansible playbook prepares a machine for templating.

Execution: `ansible-playbook -i <host>, -u template -k template-machine.yaml`
