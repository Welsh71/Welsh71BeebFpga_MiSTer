import re,sys
s=open(sys.argv[1]).read()
for n in ['fdn_index','fdn_ready','fdn_sector_hdr','fdn_sector_data','fdn_dclk']:
    s=re.sub(r'wire\s+'+n+r'\[FD_NUM\];','wire [FD_NUM-1:0] '+n+';',s)
s=s.replace('wire [6:0] fdn_track[FD_NUM];','wire [7*FD_NUM-1:0] fdn_track;').replace('wire [4:0] fdn_sector[FD_NUM];','wire [5*FD_NUM-1:0] fdn_sector;')
s=s.replace('( fdn_track[i]       )','( fdn_track[i*7+:7] )').replace('( fdn_sector[i]      )','( fdn_sector[i*5+:5] )')
s=s.replace('fdn_track[fdn]','fdn_track[fdn*7+:7]').replace('fdn_sector[fdn]','fdn_sector[fdn*5+:5]')
s=re.sub(r'(\b(?:reg|wire)\s*(?:\[[^\]]+\])?\s*\w+)\[(FD_NUM)\]', r'\1[0:\2-1]', s)
s=s.replace('always begin\n\tinteger i;','always @* begin : fdnsel\n\tinteger i;')
s=s.replace('fdn = i[WIDX:0];','fdn = i;')
s=s.replace('always @(posedge clkcpu) begin\n\treg [W:0] img_mountedD;','always @(posedge clkcpu) begin : mnt\n\treg [W:0] img_mountedD;')
s=s.replace('endcase;','endcase')
# named blocks for blocks that declare regs
n=[0]
def nm(m):
    n[0]+=1; return m.group(1)+' begin : blk%d\n%s'%(n[0],m.group(2))
s=re.sub(r'(always @\(posedge \w+\)) begin\n(\s*reg )', nm, s)
open(sys.argv[2],'w').write(s)
s=open(sys.argv[2]).read()
s=s.replace('$clog2(FD_NUM)','1').replace('parameter  IMG_TYPE        = IMG_BBC;','parameter  IMG_TYPE        = 2;')
open(sys.argv[2],'w').write(s)
s=open(sys.argv[2]).read()
a=s.index('generate'); b=s.index('endgenerate')+len('endgenerate')
gen=s[a:b]; s=s[:a]+s[b:]
m=s.index('module fdc1772 ('); e=s.index('endmodule',m)
s=s[:e]+gen+'\n'+s[e:]
open(sys.argv[2],'w').write(s)
