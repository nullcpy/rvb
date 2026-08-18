import test_mapping
apps = test_mapping.get_app_mappings()
lines = open('test_mapping_output.txt').readlines()
mapped_pkgs = set([l.split('->')[1].split('(Matched')[0].strip() for l in lines if '[Mapped]' in l])
missing = []
for repo, repo_pkgs in apps.items():
    for pkg, meta in repo_pkgs.items():
        if pkg not in mapped_pkgs:
            missing.append(f'{repo}: {pkg}')
print('\n'.join(missing))
