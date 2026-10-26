import xml.etree.ElementTree as ET,collections,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); tree=ET.parse(p); ids={e.get('id'):e for e in tree.iter() if e.get('id')}
def deref(e):
    return ids[e.get('ref')] if e is not None and e.get('ref') else e
leaf=collections.Counter(); incl=collections.Counter(); total=markers=nonrunning=0; grouped=collections.Counter()
for row in tree.iter('row'):
    fields=list(row)
    if len(fields)!=7: continue
    state=deref(fields[4]); weight=deref(fields[5]); stack=deref(fields[6])
    if state.get('fmt')!='Running': nonrunning+=1;continue
    frames=[deref(e).get('name','') for e in stack if e.tag=='frame']
    if not frames:markers+=1;continue
    w=int(weight.text or '0'); total+=w;leaf[frames[0]]+=w
    for f in set(frames):incl[f]+=w
    groups={'socket_syscalls':['recvmsg','sendmsg','recvfrom','sendto','recvmmsg','sendmmsg'], 'readiness':['poll','kevent','kqueue','dispatch_source'], 'protocol':['Connection.','conn.','crypto.','bssl','EVP_','aes_gcm'], 'allocator':['Allocator','alloc','free','mmap','munmap']}
    for name,terms in groups.items():
        if any(any(term in f for term in terms) for f in frames): grouped[name]+=w
report={'input':p.name,'usable_running_ms':total/1e6,'stackless_running_rows':markers,'nonrunning_rows':nonrunning,'leaf':[{'name':n,'ms':w/1e6,'share':w/total} for n,w in leaf.most_common(40)],'inclusive':[{'name':n,'ms':w/1e6,'share':w/total} for n,w in incl.most_common(50)],'overlapping_stack_groups':{n:{'ms':w/1e6,'share':w/total} for n,w in grouped.items()}}
out=p.with_suffix('.analysis.json');out.write_text(json.dumps(report,indent=2)); print(json.dumps(report,indent=2)[:6500])
