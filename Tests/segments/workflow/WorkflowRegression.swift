import Foundation
import SwiftUI
import CoreLocation

@main
struct WorkflowRegression {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ ok: @autoclosure () -> Bool) {
        checks += 1; let good = ok(); if !good { failures += 1 }
        print("\(good ? "PASS" : "FAIL") \(name)")
    }
    static func parsed(_ rows: [(Double,Double,Double,UInt32)], creator:String="Garmin") -> ParsedTrack {
        var p=ParsedTrack();p.lat=rows.map{$0.0};p.lon=rows.map{$0.1};p.time=rows.map{$0.2};p.segmentID=rows.map{$0.3}
        p.ele=rows.map{_ in 5};p.name="workflow";p.creator=creator;return p
    }
    static func build(_ rows: [(Double,Double,Double,UInt32)], creator:String="Garmin") -> TrackData {
        TrackData.build(parsed:parsed(rows,creator:creator),preferredMode:.single).0
    }
    static func cand(_ t:TrackData,_ a:Int,_ b:Int,kind:GapCandidate.Kind = .timeGap) -> GapCandidate {
        GapCandidate(kind:kind,indexA:a,indexB:b,tA:t.time[a],tB:t.time[b],latA:t.lat[a],lonA:t.lon[a],latB:t.lat[b],lonB:t.lon[b],meters:GeoMath.haversine(t.lat[a],t.lon[a],t.lat[b],t.lon[b]),speedInKmh:72,speedOutKmh:72).tagged(t)
    }
    static func fp(_ t:Double,_ lon:Double) -> FillPoint { FillPoint(lat:0,lon:lon,ele:5,time:t,headingDeg:90,speedMps:10,distFromPrev:10) }
    static func cp(_ t:TrackData,_ i:Int) -> ChangePoint { ChangePoint(lat:t.lat[i],lon:t.lon[i],ele:t.ele[i],time:t.time[i],originalIndex:i,segment:t.topology.segment(of:i)) }
    static func change(_ added:[ChangePoint],_ removed:[ChangePoint]=[]) -> TrackChange {
        TrackChange(kind:.fill,date:Date(timeIntervalSince1970:0),added:added,removed:removed,anchors:[],fillID:nil)
    }
    static func rowBits(_ p:ParsedTrack,_ seg:UInt32)->[[UInt64]] {
        (0..<p.count).filter{(p.segmentID.isEmpty ? 0:p.segmentID[$0]) == seg}.map{[p.lat[$0].bitPattern,p.lon[$0].bitPattern,p.ele[$0].bitPattern,p.time[$0].bitPattern]}
    }
    @MainActor static func membershipTests(_ directory:URL) throws {
        let rows:[(Double,Double,Double,UInt32)]=[(0,0,0,0),(1,0,0,1),(0,0.001,10,0),(1,0.001,10,1),(0,0.002,20,0),(1,0.002,20,1)]
        let t=build(rows), baseline=ChangeRevert.snapshot(t)
        let ca=cand(t,0,4),cb=cand(t,1,5)
        check("T07 same tA candidates have distinct complete GapID",ca.tA == cb.tA && ca.id != cb.id)
        let dictionary=[ca.id:"A",cb.id:"B"]
        check("T07 caches retain both same-time segment entries",dictionary.count==2 && dictionary[ca.id]=="A" && dictionary[cb.id]=="B")
        let ja=GapSplice.Job(indexA:0,indexB:4,points:[fp(9,0.0009)],removeInner:true,trackID:t.id,segment:0)
        let jb=GapSplice.Job(indexA:1,indexB:5,points:[FillPoint(lat:1,lon:0.0009,ele:5,time:9,headingDeg:90,speedMps:10,distFromPrev:10)],removeInner:true,trackID:t.id,segment:1)
        let ma=try GapSplice.membership(to:t,job:ja).get()
        check("T08 membership removes only A1",ma.removed == [2] && Array(ma.inner)==[2])
        let pa=try GapSplice.plan(to:t,jobs:[ja]).get()
        check("T08 A edit preserves B bits and complete membership",rowBits(pa,1)==rowBits(baseline,1) && rowBits(pa,0).count==3)
        let both=try GapSplice.plan(to:t,jobs:[ja,jb]).get()
        check("T09 overlapping global windows in different segments both apply",both.count==6 && rowBits(both,0).count==3 && rowBits(both,1).count==3)
        var bad=ja;bad.keep=[3]
        if case .failure(.foreignKeep)=GapSplice.plan(to:t,jobs:[bad]) { check("T09 foreign keep rejected",true) } else { check("T09 foreign keep rejected",false) }
        bad=ja;bad.keep=[4]
        if case .failure(.foreignKeep)=GapSplice.plan(to:t,jobs:[bad]) { check("T09 anchor cannot be inner keep",true) } else { check("T09 anchor cannot be inner keep",false) }
        if case .failure(.crossSegment)=GapSplice.plan(to:t,jobs:[GapSplice.Job(indexA:0,indexB:5,points:[],removeInner:true)]) { check("T09 cross-segment anchors rejected",true) } else { check("T09 cross-segment anchors rejected",false) }
        if case .failure(.overlappingJobs)=GapSplice.plan(to:t,jobs:[ja,ja]) { check("T09 same-segment overlap rejects entire transaction",true) } else { check("T09 same-segment overlap rejects entire transaction",false) }
        bad=ja;bad.trackID=UUID()
        if case .failure(.staleTrack)=GapSplice.plan(to:t,jobs:[jb,bad]) { check("T09 stale job rejects entire transaction",true) } else { check("T09 stale job rejects entire transaction",false) }
        let s=TrackStore(applyAppearance:false);s.track=t;s.applyCandidates(TrackStore.computeCandidates(track:t,jitter:true,merge:true),track:t)
        var item=BatchItem(candidate:ca,kind:.road,autoKind:.road);item.status = .done;item.useStraight=true
        let landing=s.landingJob(for:item,track:t,lastB:-1,forPreview:true)!
        let preview=s.previewChange(for:item,track:t,lastB:-1)!.0
        let actual=try GapSplice.membership(to:t,job:landing.job).get()
        check("T08 preview and landing share exact removed membership",preview.removed.map(\.originalIndex)==actual.removed && preview.removed.allSatisfy{$0.segment==0})
        check("T08 record and added points preserve segment",landing.rec.segment==0 && preview.added.allSatisfy{$0.segment==0})
        check("T10 manual cross-segment anchor selection rejected",{s.enterFillMode();s.selectGap(ca);return !s.setFillAnchor(nearest:3,side:true)}())
        let twin=build([(0,0,10,0),(0,0,10,1)])
        let c=change([cp(twin,0)]), other=change([])
        let reverted=try ChangeRevert.apply(to:twin,changes:[c],history:[c,other]).get()
        check("T11 same-value different-segment partial revert preserves other segment",reverted.count==1 && reverted.segmentID==[1])
        let all=try ChangeRevert.apply(to:twin,changes:[c],history:[c],baseline:baseline).get()
        check("T11 all revert preserves exact segment baseline",all.segmentID==baseline.segmentID && rowBits(all,1)==rowBits(baseline,1))
        let review=ChangeRevert.previewParsed(current:t,changes:[preview]);let reviewTrack=TrackData.build(parsed:review,preferredMode:.single).0
        check("T11 preview keeps segment column for original and added rows",review.segmentID.count==review.count && reviewTrack.topology.segments.count==2)
        let restored=ChangeRevert.reviewParsed(current:t,changes:[change([],[cp(t,2)])])
        check("T11 review deleted rows carry original segment",restored.segmentID.last==0 && restored.segmentID.count==restored.count)
        let s2=TrackStore(applyAppearance:false);s2.track=t;s2.applyCandidates(TrackStore.computeCandidates(track:t,jitter:true,merge:true),track:t)
        var itA=BatchItem(candidate:cand(t,0,4,kind:.jitter),kind:.road,autoKind:.road);itA.status = .done;itA.useStraight=true
        var itB=BatchItem(candidate:cand(t,1,5,kind:.jitter),kind:.road,autoKind:.road);itB.status = .done;itB.useStraight=true
        var state=BatchState(items:[itA,itB],trackID:t.id);state.phase = .preview;s2.batch=state
        let hook=UITestHook.shared;hook.store=s2
        let json=hook.stateJSON(s2);let object=try JSONSerialization.jsonObject(with:Data(json.utf8)) as! [String:Any]
        let list=(object["batch"] as! [String:Any])["items"] as! [[String:Any]]
        check("T07 state JSON serializes complete distinct string IDs",list[0]["id"] as? String == ca.id.description && list[1]["id"] as? String == cb.id.description)
        check("T07 batchdeleteonly accepts exact emitted ID",hook.run("batchdeleteonly",["batchdeleteonly",cb.id.description,"1"]).contains(cb.id.description))
        check("T07 exact ID mutates only its own segment",s2.batch!.items.map(\.deleteOnly)==[false,true])
        check("T07 legacy time ambiguity cannot target another segment",hook.run("batchdeleteonly",["batchdeleteonly","0.000","1"]).contains("ambiguous"))
        check("T07 ordinal operation remains supported",hook.run("batchdeleteonly",["batchdeleteonly","1","1"]).contains(cb.id.description))
        check("T07 batch preview retains simultaneous segment windows",s2.batchPreviewChanges.count==2)
        _ = directory
    }
    @MainActor static func exportTests(_ directory:URL) throws {
        let t=build([(0,0,0,0),(1,0,1,1),(0,0.001,10,0),(1,0.001,11,1),(0,0.002,20,0),(1,0.002,21,1)])
        func fill(_ a:Int,_ b:Int,_ i:Int)->GapFill {var f=GapFill(anchorA:FillAnchor(lat:t.lat[a],lon:t.lon[a],ele:5,time:t.time[a]),anchorB:FillAnchor(lat:t.lat[b],lon:t.lon[b],ele:5,time:t.time[b]),vertices:[],points:[FillPoint(lat:t.lat[i],lon:t.lon[i],ele:5,time:t.time[i],headingDeg:0,speedMps:0,distFromPrev:0)],removedInner:0);f.segment=t.topology.segment(of:a);return f}
        let fa=fill(0,4,2),fb=fill(1,5,3)
        let windows=GapFillExport.mergedWindows([fb,fa])
        check("T12 overlapping segment windows remain separate",windows.count==2 && Set(windows.map(\.segment))==[0,1])
        let indices=GapFillExport.segmentIndices(track:t,fills:[fb,fa],includeAnchors:true)
        check("T12 incremental windows contain only their segment",indices==[[0,2,4],[1,3,5]])
        let fog=GapFillExport.fogOfWorldGPX(track:t,fills:[fa,fb],name:"fixture")
        let parsed=try GPXParser.parse(data:Data(fog.utf8))
        check("T12 fog GPX roundtrip retains two independent segments",Set(parsed.segmentID).count==2 && parsed.count==6)
        let url=directory.appendingPathComponent("increments.gpx")
        try GPXWriter.write(track:t,segments:indices.map{$0.map(Int32.init)},name:"increments",to:url,synthetic:GapFillExport.syntheticKeys([fa,fb]))
        let p=try GPXParser.parse(data:Data(contentsOf:url))
        check("T12 standard increment writer retains segments",Set(p.segmentID).count==2 && p.count==6)
        let csv=GapFillExport.stepLifeCSV(track:t,fills:[fb,fa]).split(separator:"\n").dropFirst().map{$0.split(separator:",").map(String.init)}
        let expected=GeoMath.haversine(0,0,0,0.001)
        check("T13 incremental CSV flat chronological order",csv.map{$0[0]}==["10","11"])
        check("T13 incremental CSV uses same-segment predecessor",abs(Double(csv[0][7])!-expected)<1e-5 && Double(csv[1][7])!<120)
        let whole=GapFillExport.stepLifeCSVWholeTrack(track:t).split(separator:"\n").dropFirst().map{$0.split(separator:",").map(String.init)}
        check("T13 first point of each segment has zero distance/speed/heading",[0,1].allSatisfy{Double(whole[$0][4])==0 && Double(whole[$0][6])==0 && Double(whole[$0][7])==0})
        let tie=build([(0,0,0,0),(1,0,0,1),(0,0.001,10,0),(1,0.001,10,1)])
        check("T13 same-second first-point policy unchanged",GapFillExport.stepLifeCSVWholeTrack(track:tie).split(separator:"\n").count==3)
        var fbTwin=fa;fbTwin.segment=1
        check("T12 identical point values in another segment cannot leak into increment",GapFillExport.segmentIndices(track:t,fills:[fbTwin],includeAnchors:false).isEmpty)
    }
    @MainActor static func detectorTests() {
        let rows=(0..<100).flatMap { i -> [(Double,Double,Double,UInt32)] in
            let seconds=Double(i)+(i>=45 ? 60:0)
            return [(0,Double(i)*0.0002+(i>=45 ? 0.02:0),seconds,0),(1,Double(i)*0.0003+(i>=45 ? 0.03:0),seconds,1)]
        }
        let mixed=build(rows), m=TrackStore.computeCandidates(track:mixed,jitter:true,merge:true)
        for segment:UInt32 in [0,1] {
            let single=build(rows.filter{$0.3==segment}.map{($0.0,$0.1,$0.2,0)})
            let reference=TrackStore.computeCandidates(track:single,jitter:true,merge:true)
            let actual=m.cands.filter{$0.segment==segment}
            check("T10 segment \(segment) fixture exercises a real gap",!actual.isEmpty && !reference.cands.isEmpty)
            check("T10 segment \(segment) detection matches standalone",actual.map(\.tA)==reference.cands.map(\.tA) && actual.map(\.seconds)==reference.cands.map(\.seconds))
            check("T10 segment \(segment) profile excludes other segment",m.profiles[segment]==reference.profile)
            let view=SegmentSamples(mixed,range:mixed.topology.segments.first{$0.id==segment}!.range,segment:segment)
            let replay=GapDetector.replayFlags(track:mixed),alone=GapDetector.replayFlags(track:single)
            check("T10 segment \(segment) replay matches standalone",(0..<view.count).map{replay[view.global($0)]}==alone)
            let trips=m.trips.filter{$0.segment==segment}
            check("T10 segment \(segment) trips match standalone",trips.map(\.tStart)==reference.trips.map(\.tStart) && trips.map(\.tEnd)==reference.trips.map(\.tEnd))
            if let c=actual.first,let rc=reference.cands.first {
                let input=GapRouteInputs.build(mixed,ia:c.indexA,ib:c.indexB,profile:m.profiles[segment])
                let expected=GapRouteInputs.build(single,ia:rc.indexA,ib:rc.indexB,profile:reference.profile)
                check("T10 segment \(segment) context heading and sampling match standalone",input.a.heading.bearing==expected.a.heading.bearing && input.b.heading.bearing==expected.b.heading.bearing && input.sampling==expected.sampling && input.traceIndices.map{mixed.topology.segment(of:$0)}.allSatisfy{$0==segment})
                check("T10 segment \(segment) trace indices map exactly once",input.traceIndices.map{mixed.time[$0]}==expected.traceIndices.map{single.time[$0]})
            }
        }
        check("T10 cross-segment route input is invalid",!GapRouteInputs.build(mixed,ia:0,ib:3,profile:m.profile).valid)
        let boundary=build([(0,0,0,0),(20,20,1000,1)])
        check("T10 segment boundary creates no gap or jitter",TrackStore.computeCandidates(track:boundary,jitter:true,merge:true).cands.isEmpty)
    }
    @MainActor static func artifactDetectorTests() throws {
        let repository=URL(fileURLWithPath:CommandLine.arguments[2])
        let paths=["Tests/synth/replay-artefacts/a_explore_sweep.gpx", "Tests/synth/replay-artefacts/a2_explore_sawtooth_perturbed.gpx", "Tests/synth/garmin-tunnels/stale_clock_variants.gpx"]
        for path in paths {
            let p=try GPXParser.parse(data:Data(contentsOf:repository.appendingPathComponent(path)))
            let alone=TrackData.build(parsed:p,preferredMode:.single).0
            let reference=TrackStore.computeCandidates(track:alone,jitter:true,merge:true)
            var combined=ParsedTrack();combined.creator=p.creator;combined.name="duplicated segments"
            for i in 0..<p.count { for seg:UInt32 in [0,1] {combined.lat.append(p.lat[i]);combined.lon.append(p.lon[i]);combined.ele.append(p.ele[i]);combined.time.append(p.time[i]);combined.segmentID.append(seg)} }
            let t=TrackData.build(parsed:combined,preferredMode:.single).0
            let result=TrackStore.computeCandidates(track:t,jitter:true,merge:true)
            func signatures(_ c:[GapCandidate])->[String] {c.map{"\($0.kind)|\($0.tA)|\($0.tB)|\($0.chainCount)|\($0.frozenA)|\($0.innerCount)|\($0.jitterJumps)|\($0.jitterReversals)"}}
            for seg:UInt32 in [0,1] {
                check("T10 actual fixture \(path) segment \(seg) full detector matches standalone",signatures(result.cands.filter{$0.segment==seg})==signatures(reference.cands))
                check("T10 actual fixture \(path) segment \(seg) replay membership matches standalone",result.replayIndices.map(Int.init).filter{t.topology.segment(of:$0)==seg}.map{t.time[$0]}==reference.replayIndices.map{alone.time[Int($0)]})
                let profile=result.profiles[seg]!
                let own=result.cands.filter{$0.segment==seg}
                if let c=own.first,let ref=reference.cands.first {
                    let input=GapRouteInputs.build(t,ia:c.indexA,ib:c.indexB,profile:profile),expected=GapRouteInputs.build(alone,ia:ref.indexA,ib:ref.indexB,profile:reference.profile)
                    check("T10 actual fixture \(path) segment \(seg) heading/context/trace match",input.a.heading.bearing==expected.a.heading.bearing && input.b.heading.bearing==expected.b.heading.bearing && input.trace.map(\.time)==expected.trace.map(\.time) && input.traceIndices.allSatisfy{t.topology.segment(of:$0)==seg})
                }
            }
            if path.contains("a_explore") {check("T10 replay fixture actually has nonzero replay evidence",!reference.replayIndices.isEmpty)}
            if path.contains("a2_explore") {check("T10 jitter fixture actually has nonzero jitter evidence",reference.cands.contains{$0.kind == .jitter})}
            if path.contains("stale_clock") {check("T10 stale fixture actually has stale candidates",reference.cands.contains{$0.kind == .staleClock})}
        }
    }
    @MainActor static func mergeTests() {
        let id=UUID()
        func candidate(_ i:Int,segment:UInt32=0)->GapCandidate {
            var c=GapCandidate(kind:.timeGap,indexA:i*2,indexB:i*2+1,tA:Double(i*60),tB:Double(i*60+30),latA:0,lonA:0,latB:0,lonB:0.01,meters:1000,speedInKmh:30,speedOutKmh:30)
            c.trackID=id;c.segment=segment;c.pathA=i*2;c.pathB=i*2+1;return c
        }
        let candidates=(0..<4).map{candidate($0)},eligible=Set(candidates.map(\.id))
        for n in [3,4] { let result=GapDetector.mergeChains(Array(candidates.prefix(n))){eligible.contains($0.id) && eligible.contains($1.id)};check("merge \(n) original eligible candidates remains one chain",result.count==1 && result[0].chainCount==n) }
        let allowed=eligible.subtracting([candidates[1].id])
        let partial=GapDetector.mergeChains(candidates){allowed.contains($0.id) && allowed.contains($1.id)}
        check("merge sparse/pause candidate cannot be crossed",partial.map(\.chainCount)==[1,1,2])
        check("merge same-time different-segment candidates never combine",GapDetector.mergeChains([candidate(0),candidate(0,segment:1)]).count==2)
    }
    @MainActor static func retimeTests() throws {
        let meter=180/(Double.pi*GeoMath.earthRadius)
        func track(_ xs:[Double],_ time:[Double],seg:UInt32=0)->TrackData {build(zip(xs,time).map{(0,$0.0*meter,$0.1,seg)})}
        let dense=track([0,1800,1900,2000,2020],[0,1,2,100,101]);let dc=cand(dense,0,3,kind:.staleClock)
        let plan=StaleRetime.plan(track:dense,ia:0,ib:3,candidate:dc,vertices:[],radius:15)!
        check("retime dense continuous exit unchanged",plan.retimed.map(\.index)==[1,2] && plan.retimed.map(\.time)==[90,95])
        let five=track([0,1750,1800,1850,1900,1950,2000,2020],[0,1,2,3,4,5,100,101]);let fc=cand(five,0,6,kind:.staleClock)
        let fiveNew=StaleRetime.plan(track:five,ia:0,ib:6,candidate:fc,vertices:[],radius:15)!
        let fiveOld=LegacyStaleRetime.plan(track:five,ia:0,ib:6,candidate:fc,vertices:[],radius:15)!
        check("retime 5-point continuous exit matches original production Plan",fiveNew.retimed.map(\.index)==fiveOld.retimed.map(\.index) && fiveNew.retimed.map(\.time)==fiveOld.retimed.map(\.time) && fiveNew.fillB.time==fiveOld.fillB.time && fiveNew.fillB.lon==fiveOld.fillB.lon && fiveNew.vertices.count==fiveOld.vertices.count)
        let store=TrackStore(applyAppearance:false);store.track=five;store.applyCandidates(TrackStore.computeCandidates(track:five,jitter:true,merge:true),track:five);store.enterFillMode();store.selectGap(fc)
        let route=RouteDraft(source:.osrmCar,coords:[],meters:2000,snapA:0,snapB:0,endpoint:"offline",warnings:[],notes:[])
        store.applyRouteDraft(route,ia:0,ib:6)
        let singlePlan=store.currentRetimePlan()!
        var batchItem=BatchItem(candidate:fc,kind:.road,autoKind:.road);batchItem.status = .done;batchItem.draft=route
        let batchJob=store.landingJob(for:batchItem,track:five,lastB:-1)!.job
        let singlePoints=StaleRetime.landingPoints(track:five,ia:0,ib:6,plan:singlePlan,synthetic:store.currentFillPoints())
        let batchPreview=store.previewChange(for:batchItem,track:five,lastB:-1)!.0
        check("retime single/manual batch and preview actual point arrays match",singlePoints.map{$0.time.bitPattern}==batchJob.points.map{$0.time.bitPattern} && singlePoints.map{$0.lon.bitPattern}==batchJob.points.map{$0.lon.bitPattern} && batchPreview.added.map{$0.time.bitPattern}==batchJob.points.map{$0.time.bitPattern})
        let single=track([0,1900,2000,2020],[0,1,100,101]);let singleC=cand(single,0,2,kind:.staleClock)
        check("retime single continuous exit to B is retained",StaleRetime.plan(track:single,ia:0,ib:2,candidate:singleC,vertices:[],radius:15)?.retimed.map(\.index)==[1])
        let invalid=build([(0,0,0,0),(0,1780*meter,1,0),(0.01,1840*meter,2,0),(0,1900*meter,3,0),(0,2000*meter,100,0),(0,2020*meter,101,0)])
        let invalidC=cand(invalid,0,4,kind:.staleClock)
        let skip=StaleRetime.plan(track:invalid,ia:0,ib:4,candidate:invalidC,vertices:[],radius:15)!
        check("retime skipped off-route observation uses next actual kept point",skip.retimed.map(\.index)==[1,3])
        let trim=track([0,1790,1900,2000,2020],[75,76,77,100,101]);let trimC=cand(trim,0,3,kind:.staleClock)
        let trimmed=StaleRetime.plan(track:trim,ia:0,ib:3,candidate:trimC,vertices:[],radius:15)!
        check("retime A-side speed trim removes earliest kept only",trimmed.retimed.map(\.index)==[2] && trimmed.fillB.time==95)
        let tail=trimmed.retimed.map{($0.index,$0.time)}+[(3,trim.time[3])]
        check("retime A-side trim preserves continuous tail invariant",zip(tail,tail.dropFirst()).allSatisfy{!GapDetector.isBreakStep(dt:$0.1.1-$0.0.1,meters:GeoMath.haversine(trim.lat[$0.0.0],trim.lon[$0.0.0],trim.lat[$0.1.0],trim.lon[$0.1.0]))})
        let noTime=build([(0,0,0,0),(0,1900*meter,1,0),(0,2000*meter,.nan,0)])
        let invalidTimed=GapCandidate(kind:.staleClock,indexA:0,indexB:2,tA:0,tB:.nan,latA:0,lonA:0,latB:0,lonB:2000*meter,meters:2000,speedInKmh:0,speedOutKmh:0)
        check("retime missing timed anchor is safely rejected",StaleRetime.plan(track:noTime,ia:0,ib:2,candidate:invalidTimed,vertices:[],radius:15)==nil)
        let foreign=build([(0,0,0,0),(0,1900*meter,1,0),(0,2000*meter,100,0),(1,1,101,1)])
        let exitC=GapCandidate(kind:.staleClock,indexA:0,indexB:2,tA:0,tB:100,latA:0,lonA:0,latB:0,lonB:2000*meter,meters:2000,speedInKmh:0,speedOutKmh:0).tagged(foreign)
        check("retime exit fallback never borrows adjacent segment speed",StaleRetime.exitSpeed(track:foreign,ib:2,candidate:exitC)==nil && StaleRetime.plan(track:foreign,ia:0,ib:2,candidate:exitC,vertices:[],radius:15)==nil)
        check("retime speed threshold exact 350 remains unchanged",!GapDetector.isBreakStep(dt:1,meters:350/3.6) && GapDetector.isBreakStep(dt:1,meters:(350+1e-6)/3.6))
        let sparse=track([0,500,1900,2000,2020],[0,1,2,100,101]);let sc=cand(sparse,0,3,kind:.staleClock)
        let sparsePlan=StaleRetime.plan(track:sparse,ia:0,ib:3,candidate:sc,vertices:[],radius:15)!
        check("retime breaks at sparse suffix retaining only continuous exit",sparsePlan.retimed.map(\.index)==[2])
        let alone=track([0,1500,2000,2020],[0,1,100,101]);let ac=cand(alone,0,2,kind:.staleClock)
        check("retime single exit with break to B is not retained",StaleRetime.plan(track:alone,ia:0,ib:2,candidate:ac,vertices:[],radius:15)==nil)
        let duplicate=track([0,1800,1800,1900,2000],[0,1,2,3,100]);let cc=cand(duplicate,0,4,kind:.staleClock)
        let dp=StaleRetime.plan(track:duplicate,ia:0,ib:4,candidate:cc,vertices:[],radius:15)!
        check("retime duplicate position/time never creates non-increasing corrected time",zip(dp.retimed,dp.retimed.dropFirst()).allSatisfy{$0.0.time<$0.1.time})
        var nonstale=dc;nonstale=GapCandidate(kind:.timeGap,indexA:dc.indexA,indexB:dc.indexB,tA:dc.tA,tB:dc.tB,latA:dc.latA,lonA:dc.lonA,latB:dc.latB,lonB:dc.lonB,meters:dc.meters,speedInKmh:0,speedOutKmh:0).tagged(dense)
        check("retime nonstale unchanged",StaleRetime.plan(track:dense,ia:0,ib:3,candidate:nonstale,vertices:[],radius:15)==nil)
        let stop=track([0,1900,2000,2000],[0,1,100,101]);var stopc=cand(stop,0,2,kind:.staleClock);stopc=GapCandidate(kind:.staleClock,indexA:0,indexB:2,tA:0,tB:100,latA:0,lonA:0,latB:0,lonB:2000*meter,meters:2000,speedInKmh:0,speedOutKmh:0).tagged(stop)
        check("retime parking/no exit speed has no plan",StaleRetime.plan(track:stop,ia:0,ib:2,candidate:stopc,vertices:[],radius:15)==nil)
        check("retime exact break boundaries use existing predicate",GapDetector.isBreakStep(dt:20,meters:150) && !GapDetector.isBreakStep(dt:19.999,meters:150) && !GapDetector.isBreakStep(dt:20,meters:149.999))
        let mixed=build([(0,0,0,0),(1,0,0,1),(0,500*meter,1,0),(1,0.1,1,1),(0,1900*meter,2,0),(1,0.2,2,1),(0,2000*meter,100,0),(1,0.3,100,1),(0,2020*meter,101,0),(1,0.4,101,1)])
        let mc=cand(mixed,0,6,kind:.staleClock);let mp=StaleRetime.plan(track:mixed,ia:0,ib:6,candidate:mc,vertices:[],radius:15)!
        check("retime interleaved segment maps retained global index once",mp.retimed.map(\.index)==[4] && mp.retimed.map(\.time)==sparsePlan.retimed.map(\.time))
        let syn=FillPath.interpolate(a:FillAnchor(lat:0,lon:0,ele:5,time:0),vertices:mp.vertices,b:mp.fillB,spacingMeters:20)
        let points=StaleRetime.landingPoints(track:mixed,ia:0,ib:6,plan:mp,synthetic:syn)
        let job=GapSplice.Job(indexA:0,indexB:6,points:points,removeInner:true,trackID:mixed.id,segment:0)
        let after=try GapSplice.plan(to:mixed,jobs:[job]).get()
        check("retime splice does not touch interleaved B points",rowBits(after,1)==rowBits(ChangeRevert.snapshot(mixed),1))
        let added=points.map{ChangePoint(lat:$0.lat,lon:$0.lon,ele:$0.ele,time:$0.time,originalIndex:-1,segment:0)}
        let removed=(try GapSplice.membership(to:mixed,job:job).get()).removed.map{cp(mixed,$0)}
        let evidence=change(added,removed)
        let restored=try ChangeRevert.apply(to:TrackData.build(parsed:after,preferredMode:.single).0,changes:[evidence],history:[evidence],baseline:ChangeRevert.snapshot(mixed)).get()
        check("retime removed/added evidence restores entire segment baseline",restored.segmentID==mixed.segmentID && rowBits(restored,0)==rowBits(ChangeRevert.snapshot(mixed),0))
    }
    @MainActor static func garminTests(_ directory:URL) async throws {
        let repository=URL(fileURLWithPath:CommandLine.arguments[2]);let source=repository.appendingPathComponent("data/Garmin_Roma_Da_copy.gpx")
        let p=try GPXParser.parse(data:Data(contentsOf:source)),t=TrackData.build(parsed:p,preferredMode:.single).0
        let computed=TrackStore.computeCandidates(track:t,jitter:true,merge:true)
        check("real Garmin candidate baseline unchanged",t.count==46267 && computed.cands.count==100)
        guard computed.cands.count==100 else{return}
        let oldURL=repository.appendingPathComponent("Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/artifacts/logs/sec6/0047_state.log")
        let state=try JSONSerialization.jsonObject(with:Data(contentsOf:oldURL)) as! [String:Any]
        let old=(state["batch"] as! [String:Any])["items"] as! [[String:Any]]
        let store=TrackStore(applyAppearance:false);store.track=t;store.applyCandidates(computed,track:t)
        UITestHook.fakeModes=[.osrm:"ok",.valhalla:"offset 30"];UITestHook.installFakeRoutes();RouteReplay.mode = .replay(directory.appendingPathComponent("empty-replay").path)
        var reports:[[String:Any]]=[];var changed:[Int]=[]
        for (i,c) in computed.cands.enumerated() {
            check("real Garmin candidate \(i) source identity preserved",(old[i]["id"] as! Double)==c.tA)
            let engine:RoadNetwork.RouteEngine=(old[i]["source"] as! String)=="valhallaCar" ? .valhalla:.osrm
            let A=CLLocationCoordinate2D(latitude:c.latA,longitude:c.lonA),B=CLLocationCoordinate2D(latitude:c.latB,longitude:c.lonB)
            let input=GapRouteInputs.build(t,ia:c.indexA,ib:c.indexB,profile:computed.profile)
            let draft=try await RoadNetwork.carRoute(a:A,b:B,bearingA:input.a.heading.bearing,bearingB:input.b.heading.bearing,contextA:input.a.context.anchor,contextB:input.b.context.anchor,trace:input.trace,matchRadius:input.radius,seconds:c.seconds,portalA:input.portalA,portalB:input.portalB,farContextA:input.farContextA,farContextB:input.farContextB,portalFarA:input.portalFarA,portalFarB:input.portalFarB,leftHandTraffic:false,economy:true,engine:engine,failFast:false)
            var item=BatchItem(candidate:c,kind:.road,autoKind:.road);item.status = .done;item.draft=draft
            let landing=store.landingJob(for:item,track:t,lastB:-1,forPreview:true)!,risk=store.assessBatchItem(item,draft:draft,track:t)!
            if risk.risk != old[i]["risk"] as! Int {changed.append(i)}
            var report:[String:Any]=["index":i,"tA":c.tA,"risk":risk.risk,"oldRisk":old[i]["risk"]!,"retimed":landing.rec.retimed,"points":landing.job.points.count]
            if [84,97].contains(i) {
                let after=try GapSplice.plan(to:t,jobs:[landing.job]).get(),afterTrack=TrackData.build(parsed:after,preferredMode:.single).0
                let rem=TrackStore.computeCandidates(track:afterTrack,jitter:true,merge:true).cands.filter{$0.tA>=c.tA && $0.tB<=c.tB}
                check("real Garmin \(i) actual preview and splice have no residual underfill",rem.isEmpty)
                check("real Garmin \(i) expected retained/synthetic evidence",landing.rec.retimed==(i==84 ? 3:5) && landing.job.points.count-landing.rec.retimed==(i==84 ? 169:112))
                let preview=store.previewChange(for:item,track:t,lastB:-1)!.0
                check("real Garmin \(i) preview removed membership equals splice",preview.removed.map(\.originalIndex)==(try! GapSplice.membership(to:t,job:landing.job).get()).removed)
                let restored=try ChangeRevert.apply(to:afterTrack,changes:[preview],history:[preview],baseline:ChangeRevert.snapshot(t)).get()
                check("real Garmin \(i) exact restore preserves all columns and topology",restored.segmentID==t.segmentID && restored.time.map(\.bitPattern)==t.time.map(\.bitPattern) && restored.lat.map(\.bitPattern)==t.lat.map(\.bitPattern))
                report["residualCandidates"]=rem.count
            }
            reports.append(report)
        }
        check("real Garmin other 98 risks unchanged",changed==[84,97])
        check("real Garmin actual fixes retain risk thresholds",reports[84]["risk"] as! Int==10 && reports[97]["risk"] as! Int==85)
        check("offline routing guard sent zero network requests",RouteReplay.requestsSent==0 && RouteReplay.replayMisses==0)
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("garmin-actual-chain.json"))
    }
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]);try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        do {try membershipTests(directory);try exportTests(directory);detectorTests();try artifactDetectorTests();mergeTests();try retimeTests();try await garminTests(directory)}
        catch {failures += 1;print("ERROR \(error)")}
        print("WORKFLOW RESULT \(checks-failures)/\(checks), failures=\(failures)");exit(failures==0 ? 0:1)
    }
}
