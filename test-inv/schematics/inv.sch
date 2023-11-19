v {xschem version=3.4.4 file_version=1.2
}
G {}
K {}
V {}
S {}
E {}
N 1340 -360 1340 -340 {
lab=vout}
N 1340 -280 1340 -260 {
lab=vss}
N 1340 -440 1340 -420 {
lab=vdd}
N 1280 -390 1300 -390 {
lab=vin}
N 1280 -390 1280 -310 {
lab=vin}
N 1280 -310 1300 -310 {
lab=vin}
N 1270 -350 1280 -350 {
lab=vin}
N 1340 -350 1440 -350 {
lab=vout}
N 1340 -390 1350 -390 {
lab=vdd}
N 1350 -430 1350 -390 {
lab=vdd}
N 1340 -430 1350 -430 {
lab=vdd}
N 1340 -270 1350 -270 {
lab=vss}
N 1350 -310 1350 -270 {
lab=vss}
N 1340 -310 1350 -310 {
lab=vss}
C {symbols/pfet_03v3.sym} 1320 -390 0 0 {name=M1
L=0.28u
W=0.22u
nf=1
m=1
ad="'int((nf+1)/2) * W/nf * 0.18u'"
pd="'2*int((nf+1)/2) * (W/nf + 0.18u)'"
as="'int((nf+2)/2) * W/nf * 0.18u'"
ps="'2*int((nf+2)/2) * (W/nf + 0.18u)'"
nrd="'0.18u / W'" nrs="'0.18u / W'"
sa=0 sb=0 sd=0
model=pfet_03v3
spiceprefix=X
}
C {symbols/nfet_03v3.sym} 1320 -310 0 0 {name=M2
L=0.28u
W=0.22u
nf=1
m=1
ad="'int((nf+1)/2) * W/nf * 0.18u'"
pd="'2*int((nf+1)/2) * (W/nf + 0.18u)'"
as="'int((nf+2)/2) * W/nf * 0.18u'"
ps="'2*int((nf+2)/2) * (W/nf + 0.18u)'"
nrd="'0.18u / W'" nrs="'0.18u / W'"
sa=0 sb=0 sd=0
model=nfet_03v3
spiceprefix=X
}
C {devices/iopin.sym} 1440 -350 0 0 {name=p1 lab=vout}
C {devices/iopin.sym} 1340 -440 0 0 {name=p2 lab=vdd}
C {devices/iopin.sym} 1270 -350 2 0 {name=p3 lab=vin}
C {devices/iopin.sym} 1340 -260 2 0 {name=p4 lab=vss}
C {devices/code.sym} 1518.75 -391.875 0 0 {name=MODELS
only_toplevel=true
place=header
format="tcleval( @value )"
value="
.include $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/design.ngspice

.lib $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/sm141064.ngspice typical
.lib $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/sm141064.ngspice mimcap_statistical
.lib $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/sm141064.ngspice cap_mim
.lib $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/sm141064.ngspice res_typical
.lib $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/sm141064.ngspice bjt_typical
.lib $env(PDK_ROOT)/$env(PDK)/libs.tech/ngspice/sm141064.ngspice moscap_typical

"}
