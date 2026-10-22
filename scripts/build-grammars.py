#!/usr/bin/env python3
"""Maintainer-only native artifact builder. End users download the resulting archives.

Pinning: catalog/grammar-lock.json records immutable revisions and archive SHA256s.
Use --source-cache /path with python.tar.gz, rust.tar.gz, c.tar.gz, cpp.tar.gz,
swift.tar.gz to build without the network. This script never installs user tools.
"""
import argparse, hashlib, json, pathlib, re, shutil, subprocess, tarfile, tempfile, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-cache', type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path, default=ROOT/'dist/grammar-artifacts')
parser.add_argument('--release-tag', default='language-grammars-v1')
args = parser.parse_args()
lock = json.loads((ROOT/'catalog/grammar-lock.json').read_text())
args.output.mkdir(parents=True, exist_ok=True)
artifacts = []
def digest(data): return hashlib.sha256(data).hexdigest()
for entry in lock['grammars']:
    lang, version = entry['id'], entry['version']
    source = args.source_cache/(lang+'.tar.gz') if args.source_cache else None
    data = source.read_bytes() if source and source.exists() else urllib.request.urlopen(entry['sourceURL'], timeout=90).read()
    if digest(data) != entry['sourceSHA256']: raise RuntimeError('Source checksum mismatch: '+lang)
    with tempfile.TemporaryDirectory(prefix='tcode-grammar-') as tmp:
        tmp = pathlib.Path(tmp)
        archive = tmp/'source.tar.gz'; archive.write_bytes(data)
        with tarfile.open(archive) as tar:
            names = tar.getnames()
            if any(name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts for name in names): raise RuntimeError('Unsafe source archive')
            tar.extractall(tmp/'src', filter='data')
        sourceRoot = next((tmp/'src').iterdir())
        output = args.output/lang
        output.mkdir(exist_ok=True)
        module = output/'grammar.dylib'
        sources = [sourceRoot/'src/parser.c']
        scanner = sourceRoot/'src/scanner.c'
        if scanner.exists(): sources.append(scanner)
        command = ['xcrun','clang','-dynamiclib','-O2','-fvisibility=hidden','-arch','arm64','-mmacosx-version-min=27.0',
            '-Wl,-install_name,@rpath/'+lang+'-grammar.dylib', '-I'+str(sourceRoot/'src'),*map(str,sources),'-o',str(module)]
        subprocess.run(command,check=True)
        subprocess.run(['codesign','--force','--sign','-',str(module)],check=True)
        subprocess.run(['codesign','--verify','--strict',str(module)],check=True)
        subprocess.run(['lipo','-verify_arch','arm64',str(module)],check=True)
        shutil.copy(ROOT/'catalog/Queries'/f'{lang}.scm',output/'highlights.scm')
        licensePath = sourceRoot/'LICENSE'
        shutil.copy(licensePath,output/'LICENSE')
        descriptor = dict(id=lang,version=version,symbol=entry['symbol'],moduleSHA256=digest(module.read_bytes()),
            querySHA256=digest((output/'highlights.scm').read_bytes()),sourceRevision=entry['revision'],abi=entry['abi'],
            module='grammar.dylib',query='highlights.scm')
        (output/'descriptor.json').write_text(json.dumps(descriptor,indent=2)+'\n')
        filename=f'{lang}-{version}-macos27-arm64.tar.gz'
        destination=args.output/filename
        # Use a deterministic gzip/tar timestamp and regular files only.
        import gzip, io
        buffer=io.BytesIO()
        with tarfile.open(fileobj=buffer,mode='w',format=tarfile.USTAR_FORMAT) as tar:
            for name in ('descriptor.json','grammar.dylib','highlights.scm','LICENSE'):
                payload=(output/name).read_bytes(); info=tarfile.TarInfo(name)
                info.size=len(payload); info.mode=0o644; info.mtime=0
                tar.addfile(info,io.BytesIO(payload))
        destination.write_bytes(gzip.compress(buffer.getvalue(),mtime=0))
        artifacts.append(dict(descriptor=descriptor,url=f'https://github.com/LucaTufariello/tCode/releases/download/{args.release_tag}/{filename}',
            sha256=digest(destination.read_bytes()),downloadBytes=destination.stat().st_size))
        print(lang, version, destination.stat().st_size, 'download bytes,', module.stat().st_size, 'module bytes')
jsonData=json.dumps(artifacts,indent=2)+'\n'
(args.output/'grammars.json').write_text(jsonData)
(ROOT/'Sources/TCode/Resources/Syntax/grammars.json').write_text(jsonData)
print('Catalog prepared; artifacts are local until a maintainer publishes the named release.')
