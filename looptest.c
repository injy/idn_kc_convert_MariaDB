#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <idn2.h>
int main(void){
    const char *in = "xn--fiqs8s.xn--nqv7f";
    const char *exp = "xn--fiqs8s.xn--nqv7f";
    int bad=0;
    char *samples[6]; int ns=0;
    for(int i=0;i<2000;i++){
        char *ace=NULL;
        int rc = idn2_to_ascii_8z(in,&ace,IDN2_TRANSITIONAL);
        if(rc!=IDN2_OK || !ace){ if(ace)free(ace); printf("call %d rc=%d\n",i,rc); continue; }
        if(strcmp(ace,exp)!=0){
            bad++;
            if(ns<6){ samples[ns++]=strdup(ace); }
        }
        free(ace);
    }
    for(int i=0;i<ns;i++){ printf("CORRUPT sample %d: [%s]\n", i, samples[i]); free(samples[i]); }
    printf("done. corrupted=%d/2000\n", bad);
    return 0;
}
