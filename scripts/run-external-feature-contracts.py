#!/usr/bin/env python3
"""Compile two independent feature modules and execute their real Store consumer.

Uses already-built actual-source Linux engine objects. This is an advanced
manual-mapping boundary check, not native @FeatureRoute/SwiftUI/product proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--modules',required=True,type=Path)
p.add_argument('--build-provenance',required=True,type=Path)
p.add_argument('--scratch',required=True,type=Path)
p.add_argument('--objects-root',type=Path,help='SwiftPM per-target object root for non-aggregate layouts')
a=p.parse_args(); a.scratch.mkdir(parents=True,exist_ok=True)
record={'scope':'two independent external feature modules, manual mappings, real one-Store runtime',
        'excluded':['shipped package products','native SwiftUI','generated @FeatureRoute runtime','Apple ABI/full compiler matrix'],
        'build_provenance':json.loads(a.build_provenance.read_text()),'commands':[],'files':{}}
common=['swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',
        '-module-cache-path',str(a.scratch/'module-cache'),'-I',str(a.modules),'-I',str(a.scratch)]
def run(command,name):
 r=subprocess.run(command,capture_output=True,text=True)
 (a.scratch/(name+'.log')).write_text(r.stdout+r.stderr)
 record['commands'].append({'command':command,'exit_code':r.returncode})
 (a.scratch/'provenance.json').write_text(json.dumps(record,indent=2)+'\n')
 if r.returncode: raise SystemExit(r.returncode)
 return r.stdout
for module,route in [('FeatureAlpha','AlphaRoute'),('FeatureBeta','BetaRoute')]:
 source='import InnoRouterCore\npublic enum '+route+': String, Route, Codable { case home, detail }\n'
 path=a.scratch/(module+'.swift');path.write_text(source)
 record['files'][path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
 run(common+['-parse-as-library','-emit-module','-emit-object','-module-name',module,
             '-emit-module-path',str(a.scratch/(module+'.swiftmodule')),'-o',str(a.scratch/(module+'.o')),str(path)],module)
source='''import Foundation
import InnoRouterCore
import InnoRouterSwiftUI
import FeatureAlpha
import FeatureBeta

enum AppRoute: Route { case alpha(AlphaRoute), beta(BetaRoute) }
@main struct ExternalFeatureConsumer {
    @MainActor static func main() async throws {
        let root = try RouterContainerState<AppRoute>(style: .tabs, selection: "alpha", branches: [
            RouterBranch(id: "alpha"), RouterBranch(id: "beta")
        ])
        let store = try RouterStore(initialState: try RouterState(root: .container(root)))
        let alphaMap = RouterFeatureMapping<AppRoute, AlphaRoute>(id: "alpha", namespace: "consumer.alpha", route: .init(
            embed: AppRoute.alpha, extract: { if case .alpha(let route) = $0 { route } else { nil } }
        ))
        let betaMap = RouterFeatureMapping<AppRoute, BetaRoute>(id: "beta", namespace: "consumer.beta", route: .init(
            embed: AppRoute.beta, extract: { if case .beta(let route) = $0 { route } else { nil } }
        ))
        let alpha = RouterFeatureScope(parent: store.scope(at: ["alpha"]), mapping: alphaMap)
        let beta = RouterFeatureScope(parent: store.scope(at: ["beta"]), mapping: betaMap)
        guard case .applied = await alpha.perform(.push(.detail)) else { fatalError("alpha request rejected") }
        precondition(store.state.node(at: ["alpha"]) == .stack(path: [.alpha(.detail)]))
        precondition(store.state.node(at: ["beta"]) == .stack())
        guard case .applied = await beta.perform(.push(.home)) else { fatalError("beta request rejected") }
        precondition(store.revision == 2)
        guard case .applied = await alpha.perform(.apply(.init(state: .rootStack(path: [.home])))) else {
            fatalError("feature replacement rejected")
        }
        let afterReplace = store.state
        guard case .rejected = await alpha.perform(.push(.detail)) else { fatalError("old feature acquired new ownership") }
        precondition(store.state == afterReplace && store.revision == 3)
        guard case .applied = await beta.perform(.push(.detail)) else { fatalError("unrelated sibling was invalidated") }
        let fresh = RouterFeatureScope(parent: store.scope(at: ["alpha"]), mapping: alphaMap)
        guard case .applied = await fresh.perform(.push(.detail)) else { fatalError("new owner could not navigate") }
        precondition(store.state.node(at: ["alpha"]) == .stack(path: [.alpha(.home), .alpha(.detail)]))
        precondition(store.state.node(at: ["beta"]) == .stack(path: [.beta(.home), .beta(.detail)]))
        precondition(store.revision == 5)
        let empty = RouterStore<AlphaRoute>()
        precondition(empty.revision == 0 && empty.state == .rootStack)
        let budget = RouterResourceBudget(snapshot: try .init(maximumStackPath: 1))
        let configuration = RouterStoreConfiguration<AlphaRoute>(resourceBudget: budget)
        do {
            _ = try RouterStore(initialPath: [AlphaRoute.home, .detail], configuration: configuration)
            fatalError("Oversized external initialization was accepted")
        } catch is RouterResourceLimitFailure {}
        let bounded = try RouterStore(initialPath: [AlphaRoute.home], configuration: configuration)
        guard case .rejected(_, _, _, .resourceLimit) = await bounded.perform(.push(.detail)) else {
            fatalError("External action bypassed the owner budget")
        }
        precondition(bounded.state == .rootStack(path: [.home]) && bounded.revision == 0)
        guard case .applied = await bounded.perform(.pop(count: 1)) else { fatalError("Capacity was not released") }
        guard case .applied = await bounded.perform(.push(.detail)) else { fatalError("Released capacity was not reusable") }
        precondition(bounded.revision == 2)
        print("PASS external two-feature consumer: isolation, one-store revisions, replacement expiry, sibling continuity, reacquisition")
    }
}
'''
path=a.scratch/'Consumer.swift';path.write_text(source)
record['files'][path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
modules=['InnoRouterCore','InnoRouterDeepLink','InnoRouterSwiftUI','OSLog']
objects=([obj for module in modules for obj in sorted((a.objects_root/(module+'.build')).glob('*.o'))]
         if a.objects_root else [a.modules/(module+'.o') for module in modules])
if not objects: raise SystemExit('No engine object files found')
objects += [a.scratch/'FeatureAlpha.o', a.scratch/'FeatureBeta.o']
for obj in objects: record['files'][str(obj)]=hashlib.sha256(obj.read_bytes()).hexdigest()
binary=a.scratch/'ExternalFeatureConsumer'
run(common+['-parse-as-library','-module-name','ExternalFeatureConsumer',str(path),*map(str,objects),'-o',str(binary)],'consumer-build')
output=run([str(binary)],'consumer-run')
if not output.startswith('PASS external two-feature consumer:'): raise SystemExit('Missing consumer completion marker')
record['completed']=True
record['toolchain']=subprocess.check_output(['swiftc','--version'],text=True).strip()
(a.scratch/'provenance.json').write_text(json.dumps(record,indent=2)+'\n')
print(output,end='')
