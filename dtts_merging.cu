
#include "dtts_merging.h"
#include "external/SpeedIT_Classic/si_classic.h"

#include "cublas.h"

#define TILE_WIDTH 16


Gradient get_gradient(Image& src)
{

    Gradient grad(Image(src.width(),src.height()),Image(src.width(),src.height()));

    for (int i=0; i<src.width(); i++) for (int j=0; j<src.height(); j++)
        {
            grad.first(i,j)  = src.getPixelXY(i,j)-src.getPixelXY(i-1,j);
            grad.second(i,j) = src.getPixelXY(i,j)-src.getPixelXY(i,j-1);
        }

    return grad;
}

Gradient get_gradient_r(Image& src)
{

    Gradient grad(Image(src.width(),src.height()),Image(src.width(),src.height()));

    for (int i=0; i<src.width(); i++) for (int j=0; j<src.height(); j++)
        {
            grad.first(i,j)  = src.getPixelXY(i,j)-src.getPixelXY(i-1,j);
            grad.second(i,j) = src.getPixelXY(i,j)-src.getPixelXY(i,j-1);
        }

    return grad;
}

Image get_divergent(Gradient grad)
{
    Image div(grad.first.width(),grad.first.height());
    Image gradXX = get_gradient_r(grad.first).first;
    Image gradYY = get_gradient_r(grad.second).second;

    for (int i=0; i<grad.first.width(); i++) for (int j=0; j<grad.first.height(); j++)
        {
            div(i,j) = gradXX(i,j)+gradYY(i,j);
        }
    return div;
}

Image get_divergent(Image& src)
{
    return get_divergent(get_gradient(src));
}

float w_eqn(float x)
{
    if (x>1)    return 0;
    return (x*x-1)*(x*x-1);
}

int near2seam( node_t p, vector<node_t> seam)
{
    float tmp, minim = 10000000;
    int kres = -1;
    for (unsigned int k=0; k<seam.size(); k++)
    {
        tmp = ( (p.x - seam[k].x)*(p.x - seam[k].x) ) + ( (p.y - seam[k].y)*(p.y - seam[k].y) );
        if (tmp<minim)
        {
            minim = tmp;
            kres = k;
        }
    }
    return kres;
}

void wire_deform_shepard(Image pdest, Image& psrc, Image& mask, vector<node_t> seam, Image& target, float doff)
{
    Image ndest(pdest), nsrc(psrc);

    if (seam.size()==0)    return;

    for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
        {

            node_t p(x,y);
            int k = near2seam(p,seam);
            float w = w_eqn(ndistance(p,seam[k])/(doff));

            //if (mask(x,y)==vSINK || mask(x,y)==vsSINK)
            {
                pdest(x,y) = ndest(x,y)+w*(target(k)-ndest(seam[k].x,seam[k].y));
                //pdest(x,y) = w*psrc(x,y)+(1-w)*pdest(x,y);

            }

            //if (mask(x,y)<=vsSINK)
            {
                psrc(x,y) = nsrc(x,y)+w*(target(k)-nsrc(seam[k].x,seam[k].y));
                //if (x==seam[k].x || y==seam[k].y)
                psrc(x,y) = w*pdest(x,y)+(1-w)*psrc(x,y);
            }
        }
}

float graphCut_cost(Image* dest, Image* patch, int dx, int dy, bool gradient, bool severe)
{

    int w = patch->width();
    int h = patch->height();
    vector<cut_node> cut;

    int* nodes = new int [w*h];

    // Determine overlapping area
    for (int y=0; y<h; y++)
    	for (int x=0; x<w; x++)
        {

            if (dest->inBounds(x+dx, y+dy) && (*dest)(x+dx,y+dy)>BG){
            	nodes[x+y*w] = cut.size();
            	cut.push_back( cut_node (node_t(x,y),true) );
            }
             else
             	nodes[x+y*w] = -1;
        }

    if (cut.size()==0)
    {
    	delete [] nodes;
        return 0.;
    }

    //Find out if a pixel is coming from source (1) or sink (-1) or neither (0)
    vector<int> parent(cut.size());
    int sink_ct=0, src_ct = 0;
    for (unsigned int k=0; k<cut.size(); k++)
    {

        parent[k] = 0;
        node_t p = cut[k].first;
        int ix = p.x+dx;
        int iy = p.y+dy;

        if (p.x==0 || p.y==0 || p.x==w-1 || p.y==h-1)
        {
            parent[k] += -1;
            sink_ct++;
        }
        if ( dest->getPixelXY(ix, iy+1)==BG || dest->getPixelXY(ix,iy-1)==BG || dest->getPixelXY(ix+1, iy)==BG || dest->getPixelXY(ix-1,iy)==BG || ( (!severe) && (ix==0 || iy==0 || ix==dest->width()-1 || iy==dest->height()-1) ))
        {
            parent[k] += 1;
            src_ct++;
        }
    }

    GraphType *G= new GraphType(cut.size(),4*cut.size());
    G->add_node(cut.size());

    if (src_ct==0)       parent[cut.size()/4] = 1;
    if (sink_ct==0)       parent[0] = -1;

    float val = 0 ;

    for (unsigned int k=0; k<cut.size(); k++)
    {
        node_t p = cut[k].first;
	if (p.y+1<h && nodes[(p.y+1)*w+p.x]>=0){
		node_t q(p.x,p.y+1);
		int l = nodes[(p.y+1)*w+p.x];
		float s_val_p = 0 , s_val_q = 0, d_val_p =0 , d_val_q = 0;
                if (gradient)
                {
                    	d_val_p = fabs ( dest->getPixelXY(p.x+dx+1,p.y+dy) - (*dest)(p.x+dx,p.y+dy) );
                        d_val_q = fabs ( dest->getPixelXY(q.x+dx+1,q.y+dy) - (*dest)(q.x+dx,q.y+dy) );
                        s_val_p = fabs ( patch->getPixelXY(p.x+1,p.y) - (*patch)(p.x,p.y) );
                        s_val_q = fabs ( patch->getPixelXY(q.x+1,q.y) - (*patch)(q.x,q.y) );
                }

        	val = fabs( (*patch)(p.x,p.y) - (*dest)(p.x+dx,p.y+dy) )+fabs ( (*patch)(q.x,q.y) - (*dest)(q.x+dx,q.y+dy) );
		//cout<< d_val_p + d_val_q + s_val_p +  s_val_q<<" ";
		if (d_val_p + d_val_q + s_val_p +  s_val_q > 0.)
		     val/= d_val_p + d_val_q + s_val_p +  s_val_q;

		G->add_edge( k,l,val,val);
	}

	if (p.x+1<w && nodes[(p.y)*w+p.x+1]>=0){
		node_t q(p.x+1,p.y);
		int l = nodes[(p.y)*w+p.x+1];
		float s_val_p = 0 , s_val_q = 0, d_val_p =0 , d_val_q = 0;
                if (gradient)
                {
                        d_val_p = fabs ( dest->getPixelXY(p.x+dx,p.y+dy+1) - (*dest)(p.x+dx,p.y+dy) );
                        d_val_q = fabs ( dest->getPixelXY(q.x+dx,q.y+dy+1) - (*dest)(q.x+dx,q.y+dy) );
                        s_val_p = fabs ( patch->getPixelXY(p.x,p.y+1) - (*patch)(p.x,p.y) );
                        s_val_q = fabs ( patch->getPixelXY(q.x,q.y+1) - (*patch)(q.x,q.y) );

                }

        	val = fabs( (*patch)(p.x,p.y) - (*dest)(p.x+dx,p.y+dy) )+fabs( (*patch)(q.x,q.y) - (*dest)(q.x+dx,q.y+dy) );
		//cout<< d_val_p + d_val_q + s_val_p +  s_val_q<<" ";
		if (d_val_p + d_val_q + s_val_p +  s_val_q > 0.)
		     val/= d_val_p + d_val_q + s_val_p +  s_val_q;

		G->add_edge( k,l,val,val);
	}

        if (parent[k]==-1)  //Come from sink
            G->add_tweights(k,0,MAX_CAPACITY);
        else if (parent[k]==1)  //Come from source
            G->add_tweights(k,MAX_CAPACITY,0);
    }
	delete [] nodes;
    float res = G->maxflow();
    //cout<<"Flow: "<<res<<endl;
    delete G;


    return res;
}

Image* graphCut(Image* dest, Image* patch, int dx, int dy, bool gradient, bool severe)
{

    int w = patch->width();
    int h = patch->height();
    vector<cut_node> cut;
    Image* mask = new Image(w,h);
    Image* tmp = new Image(w,h);

    int* nodes = new int [w*h];

    // Determine overlapping area
    for (int y=0; y<h; y++)
    	for (int x=0; x<w; x++)
        {

            if (dest->inBounds(x+dx, y+dy) && (*dest)(x+dx,y+dy)>BG){
            	nodes[x+y*w] = cut.size();
            	cut.push_back( cut_node (node_t(x,y),true) );
            }
             else
             	nodes[x+y*w] = -1;
        }

    if (cut.size()==0)
    {
    	delete [] nodes;
        return mask;
    }

    //Find out if a pixel is coming from source (1) or sink (-1) or neither (0)
    vector<int> parent(cut.size());
    int sink_ct = 0, src_ct = 0;
    for (unsigned int k=0; k<cut.size(); k++)
    {

        parent[k] = 0;
        node_t p = cut[k].first;
        int ix = p.x+dx;
        int iy = p.y+dy;

        if (p.x==0 || p.y==0 || p.x==w-1 || p.y==h-1)
        {
            parent[k] += -1;
            sink_ct++;
        }

        if ( dest->getPixelXY(ix, iy+1)==BG || dest->getPixelXY(ix,iy-1)==BG || dest->getPixelXY(ix+1, iy)==BG || dest->getPixelXY(ix-1,iy)==BG || ( (!severe) && (ix==0 || iy==0 || ix==dest->width()-1 || iy==dest->height()-1) ))
        {
            parent[k] += 1;
            src_ct++;
        }
    }

    GraphType *G= new GraphType(cut.size(),4*cut.size());
    G->add_node(cut.size());

    float val = 0.;

    if (src_ct==0)       parent[cut.size()/4] = 1;
    if (sink_ct==0)       parent[0] = -1;

    for (unsigned int k=0; k<cut.size(); k++)
    {
        node_t p = cut[k].first;
	if (p.y+1<h && nodes[(p.y+1)*w+p.x]>=0){
		node_t q(p.x,p.y+1);
		int l = nodes[(p.y+1)*w+p.x];
		float s_val_p = 0 , s_val_q = 0, d_val_p =0 , d_val_q = 0;
                if (gradient)
                {
                    	d_val_p = fabs ( dest->getPixelXY(p.x+dx+1,p.y+dy) - (*dest)(p.x+dx,p.y+dy) );
                        d_val_q = fabs ( dest->getPixelXY(q.x+dx+1,q.y+dy) - (*dest)(q.x+dx,q.y+dy) );
                        s_val_p = fabs ( patch->getPixelXY(p.x+1,p.y) - (*patch)(p.x,p.y) );
                        s_val_q = fabs ( patch->getPixelXY(q.x+1,q.y) - (*patch)(q.x,q.y) );
                }

        	val = fabs( (*patch)(p.x,p.y) - (*dest)(p.x+dx,p.y+dy) )+fabs( (*patch)(q.x,q.y) - (*dest)(q.x+dx,q.y+dy) );
		//cout<< d_val_p + d_val_q + s_val_p +  s_val_q<<" ";
		if (d_val_p + d_val_q + s_val_p +  s_val_q > 0.)
		     val/= d_val_p + d_val_q + s_val_p +  s_val_q;

		G->add_edge( k,l,val,val);
	}

	if (p.x+1<w && nodes[(p.y)*w+p.x+1]>=0){
		node_t q(p.x+1,p.y);
		int l = nodes[(p.y)*w+p.x+1];
		float s_val_p = 0 , s_val_q = 0, d_val_p =0 , d_val_q = 0;
                if (gradient)
                {
                        d_val_p = fabs ( dest->getPixelXY(p.x+dx,p.y+dy+1) - (*dest)(p.x+dx,p.y+dy) );
                        d_val_q = fabs ( dest->getPixelXY(q.x+dx,q.y+dy+1) - (*dest)(q.x+dx,q.y+dy) );
                        s_val_p = fabs ( patch->getPixelXY(p.x,p.y+1) - (*patch)(p.x,p.y) );
                        s_val_q = fabs ( patch->getPixelXY(q.x,q.y+1) - (*patch)(q.x,q.y) );

                }

        	val = fabs( (*patch)(p.x,p.y) - (*dest)(p.x+dx,p.y+dy) )+fabs( (*patch)(q.x,q.y) - (*dest)(q.x+dx,q.y+dy) );
		//cout<< d_val_p + d_val_q + s_val_p +  s_val_q<<" ";
		//cout<< p.x<<"/"<<p.y <<" "<<q.x<<"/"<<q.y<<" "<<d_val_p + d_val_q + s_val_p +  s_val_q<<" "<<val<<endl;
		//cout<< p.x<<"/"<<p.y <<" "<<q.x<<"/"<<q.y<<" "<<(*patch)(p.x,p.y)<<" "<<(*patch)(q.x,q.y)<<endl;
		if (d_val_p + d_val_q + s_val_p +  s_val_q > 0.)
		     val/= d_val_p + d_val_q + s_val_p +  s_val_q;

		G->add_edge( k,l,val,val);
	}

        if (parent[k]==-1)  //Come from sink
            G->add_tweights(k,0,MAX_CAPACITY);
        else if (parent[k]==1)  //Come from source
            G->add_tweights(k,MAX_CAPACITY,0);
    }
    delete [] nodes;
    G->maxflow();
   // cout<<"Flow: "<<G->maxflow()<<endl;
   // cin.get();
    for (unsigned int k=0; k<cut.size(); k++)
    {
        node_t pnode = cut[k].first;
        if(G->what_segment(k) == GraphType::SINK)
        {
            cut[k].second=false;
        }
    }
    delete G;

    for (unsigned int k=0; k<cut.size(); k++)
    {
        node_t p = cut[k].first;
        if (!cut[k].second)   (*tmp)(p.x,p.y) = vSINK;
        else 	(*tmp)(p.x,p.y) = vSOURCE;
    }

    for (int i=0; i<w; i++)
        for (int j=0; j<h; j++)
        {

            if ( (*tmp)(i,j)==vSINK)
            {
                (*mask)(i,j)=vSINK;
                if ( tmp->getPixelXY(i-1,j)==vSOURCE || tmp->getPixelXY(i+1,j)==vSOURCE || tmp->getPixelXY(i,j-1)==vSOURCE || tmp->getPixelXY(i,j+1)==vSOURCE ||
                        tmp->getPixelXY(i-1,j-1)==vSOURCE || tmp->getPixelXY(i+1,j-1)==vSOURCE || tmp->getPixelXY(i-1,j+1)==vSOURCE ||tmp->getPixelXY(i+1,j+1)==vSOURCE )
                    (*mask)(i,j) = vsSINK;
            }
            else if ( (*tmp)(i,j)==vSOURCE)
            {
                (*mask)(i,j)=vSOURCE;
                if ( tmp->getPixelXY(i-1,j)==vSINK || tmp->getPixelXY(i+1,j)==vSINK || tmp->getPixelXY(i,j-1)==vSINK || tmp->getPixelXY(i,j+1)==vSINK ||
                        tmp->getPixelXY(i-1,j-1)==vSINK || tmp->getPixelXY(i+1,j-1)==vSINK || tmp->getPixelXY(i-1,j+1)==vSINK ||tmp->getPixelXY(i+1,j+1)==vSINK )
                    (*mask)(i,j) = vsSOURCE;
            }

        }

    /*for (int x=0; x<w; x++)
        for (int y=0; y<h; y++){
            if (!dest->inBounds(x+dx, y+dy))
                (*mask)(x,y) = vSINK;
        }*/
    delete tmp;
    //mask->savePGM("/tmp/mask.pgm");
    return mask;
}

void paste_cut (Image* dest, Image* patch, int dx, int dy)
{
    Image* mask = graphCut(dest,patch,dx,dy);    //Tested and severe=false performs the best

    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
        {
            if (dest->inBounds(i+dx,j+dy) && (*mask)(i,j)<=vsSOURCE)
            {
                //cout<<i+dx<<" "<<j+dy<<" "<<dest->width()<<" "<<dest->height()<<" "<< dest->inBounds(i+dx,j+dy)<<endl;
                (*dest)( i+dx,j+dy) = (*patch)(i,j) ;
            }
        }

    delete mask;
}

class seaminfo{
  public:
	node_t pt;
	float diffy, diffx;
	__host__ __device__ seaminfo(node_t p = node_t(0,0), float gx=0, float gy=0 ){
		pt = p; diffx=gx; diffy=gy;
	}
};

// Square root approximation - Babylonian method
__host__ __device__
float sqroot(float s) {

	float xn = s / 2.0;
	float lastX = 0.0;

	// Looping this way ensures we perform only as many calculations as necessary.
	// Can be replaced with a static for loop if you really want to.
	while(xn != lastX) {
	lastX = xn;
	xn = (xn + s/xn) / 2.0;
	}

	return xn;

}
__global__
void sinterpolate_gpu(point_t* points,seaminfo* seaminf, int nsize, int bsize, float drange){
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    if (i<bsize && j<bsize && points[i+j*bsize].x>-1e3 ){

    		    node_t p(i,j);
                    float wtot=0, wsrcx=0, wsrcy=0;

                    for (unsigned int k=0; k<nsize; k++)
                    {
			float d  = sqrtf((p.x-seaminf[k].pt.x)*(p.x-seaminf[k].pt.x) + (p.y-seaminf[k].pt.y)*(p.y-seaminf[k].pt.y));

                        float w = powf((drange-d)/(drange*d),4);	//powf(((d*d)/(drange*drange))-1.,2);
                        wtot = wtot+w;
                        if (d <=  drange)
                        {
                            wsrcx += w*(seaminf[k].diffx);
                            wsrcy += w*(seaminf[k].diffy);
                        }

                    }


                    points[i+j*bsize].x = (wsrcx/wtot);
                    points[i+j*bsize].y = (wsrcy/wtot);
    }

}

__host__
void sinterpolate_cpu(point_t* points,seaminfo* seaminf, int nsize, int bsize, float drange){
    for (int i=0; i<bsize; i++)
        for (int j=0; j<bsize; j++)
        	 if (points[i+j*bsize].x>-1e3 ){

    		    node_t p(i,j);
                    float wtot=0, wsrcx=0, wsrcy=0;

                    for (int k=0; k<nsize; k++)
                    {
			float d  = sqrtf((p.x-seaminf[k].pt.x)*(p.x-seaminf[k].pt.x) + (p.y-seaminf[k].pt.y)*(p.y-seaminf[k].pt.y));

                        float w = powf((drange-d)/(drange*d),4);	//powf(((d*d)/(drange*drange))-1.,2);
                        wtot = wtot+w;
                        if (d <=  drange)
                        {
                            wsrcx += w*(seaminf[k].diffx);
                            wsrcy += w*(seaminf[k].diffy);
                        }

                    }


                    points[i+j*bsize].x = (wsrcx/wtot);
                    points[i+j*bsize].y = (wsrcy/wtot);
    }

}

void sinterpolate(Image& patch,  Image& mask, vector<node_t> seam, vector<float> tar, float drange)
{
    if (seam.size()>0)
    {

        //cout<<"Start: "<<endl;
        for (int i=0; i<patch.width(); i++)
            for (int j=0; j<patch.height(); j++)
                if ( (mask)(i,j) < vsSINK )
                {

                    node_t p(i,j);
                    float wtot=0, wsrc=0;

                    for (unsigned int k=0; k<seam.size(); k++)
                    {

                        float d  = ndistance(p,seam[k]);
                        float w = powf((drange-d)/(drange*d),4);
                        wtot += w;
                        if (d <=  drange)
                        {
                            wsrc += w*tar[k];
                        }

                    }
                    patch(i,j) = patch(i,j) + (wsrc/wtot);

                }
    }
}

void sinterpolate_g(Gradient& patch_g, Image& mask, vector<node_t> seam, vector<float> xdiff, vector<float> ydiff, float drange)
{
    //int w = patch_g.first.width();
    //int h = patch_g.second.height();

    //float* gradx_dev;		cudaMalloc((void**) &gradx_dev, sizeof(float)*w*h);
    //float* grady_dev;		cudaMalloc((void**) &grady_dev, sizeof(float)*w*h);

    if (seam.size()>0)
    {
        for (int i=0; i<patch_g.first.width(); i++)
            for (int j=0; j<patch_g.first.height(); j++)
                if ( (mask)(i,j) < vsSINK )
                {

                    node_t p(i,j);
                    float wtot=0, wsrcx=0, wsrcy=0;

                    for (unsigned int k=0; k<seam.size(); k++)
                    {

                        float d  = ndistance(p,seam[k]);
                        float w = powf((drange-d)/(drange*d),4); //powf(((d*d)/(drange*drange))-1.,2);
                        wtot += w;
                        if (d <=  drange)
                        {
                            wsrcx += w*xdiff[k];
                            wsrcy += w*ydiff[k];
                        }

                    }
                    patch_g.first(i,j) = patch_g.first(i,j)+ (wsrcx/wtot);
                    patch_g.second(i,j) = patch_g.second(i,j) + (wsrcy/wtot);

                }
    }
}

#include <cusparse.h>
#include <cublas.h>

void cgrad (int N, int nnz, float* vals, int* colind, int* rowptr, float* X, float* B, int* niter, float* epsilon){

 cublasInit();
  //for (int k=0; k<N; k++){
    //   X[k] = 0.0;
 	//cout<<b[k]<<" ";
	//}
//cout<<endl;

 float* vals_dev;        cublasAlloc(nnz, sizeof(float), (void**) &vals_dev);
 int* colind_dev;        cublasAlloc(nnz, sizeof(int), (void**) &colind_dev);
 int * rowptr_dev;       cublasAlloc(N+1, sizeof(int), (void**) &rowptr_dev);
 float * X_dev;       cublasAlloc(N, sizeof(float), (void**) &X_dev);
 float * B_dev;       cublasAlloc(N, sizeof(float), (void**) &B_dev);
 //int* niter_dev;         cublasAlloc(1, sizeof(int), (void**) &niter_dev);
 //float* epsilon_dev;     cublasAlloc(1, sizeof(float), (void**) &epsilon_dev);

  cublasSetVector (nnz, sizeof(float),vals, 1, vals_dev, 1);
  cublasSetVector (nnz, sizeof(int),colind, 1, colind_dev, 1);
  cublasSetVector (N+1, sizeof(int),rowptr, 1, rowptr_dev, 1);
  cublasSetVector (N, sizeof(float),X, 1, X_dev, 1);
  cublasSetVector (N, sizeof(float),B, 1, B_dev, 1);
  //*niter = 0;


/*
cudaDeviceProp deviceProp;
    int devID = 0;
    if (devID < 0) {
       printf("exiting...\n");
       exit(0);
    }
    cudaGetDeviceProperties(&deviceProp, devID) ;
 printf("> GPU device has %d Multi-Processors, SM %d.%d compute capabilities\n\n",
		deviceProp.multiProcessorCount, deviceProp.major, deviceProp.minor);

    int version = (deviceProp.major * 0x10 + deviceProp.minor);
    if(version < 0x11)
    {
        printf("Requires a minimum CUDA compute 1.1 capability\n");
        printf("PASSED");
        cudaThreadExit();
    }*/

  //sicl_gscsrcg_seq( N, vals, colind, rowptr, X, B,P_NONE,niter,epsilon);
  sicl_gscsrcg( N, vals_dev, colind_dev, rowptr_dev, X_dev, B_dev,P_NONE,niter,epsilon);
  //bicgstab_kernel( N, vals_dev, colind_dev, rowptr_dev, X_dev, B_dev,P_NONE,niter,epsilon);
  //sicl_gscsrmv( N, vals_dev, colind_dev, rowptr_dev, X_dev, B_dev);

  /*int max_iter  =10000;

    cusparseHandle_t handle = 0;
    cusparseStatus_t status;
    status = cusparseCreate(&handle);
    if (status != CUSPARSE_STATUS_SUCCESS) {
        fprintf( stderr, "!!!! CUSPARSE initialization error\n" );
        return ;
    }

    cusparseMatDescr_t descr = 0;
    status = cusparseCreateMatDescr(&descr);
    if (status != CUSPARSE_STATUS_SUCCESS) {
        fprintf( stderr, "!!!! CUSPARSE cusparseCreateMatDescr error\n" );
        return ;
    }
    cusparseSetMatType(descr,CUSPARSE_MATRIX_TYPE_GENERAL);
    cusparseSetMatIndexBase(descr,CUSPARSE_INDEX_BASE_ZERO);

    float a, b, r0, r1;
    float *d_Ax;
    float *d_p;
    cudaMalloc((void**)&d_p, N*sizeof(float));
    cudaMalloc((void**)&d_Ax, N*sizeof(float));

    cusparseScsrmv(handle,CUSPARSE_OPERATION_NON_TRANSPOSE, N, N, 1.0, descr, vals_dev, rowptr_dev, colind_dev, X_dev, 0.0, d_Ax);
    cublasSaxpy(N, -1.0, d_Ax, 1, B_dev, 1);
    r1 = cublasSdot(N, B_dev, 1, B_dev, 1);

    int k = 1;
    const float tol = 1e-5;

    while (r1 > tol*tol && k <= max_iter) {
        if (k > 1) {
            b = r1 / r0;
            cublasSscal(N, b, d_p, 1);
            cublasSaxpy(N, 1.0, B_dev, 1, d_p, 1);
        } else {
            cublasScopy(N, B_dev, 1, d_p, 1);
        }

        cusparseScsrmv(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, N, N, 1.0, descr, vals_dev, rowptr_dev, colind_dev,d_p, 0.0, d_Ax);
        a = r1 / cublasSdot(N, d_p, 1, d_Ax, 1);
        cublasSaxpy(N, a, d_p, 1, X_dev, 1);
        cublasSaxpy(N, -a, d_Ax, 1, B_dev, 1);

        r0 = r1;
        r1 = cublasSdot(N, B_dev, 1, B_dev, 1);
        cudaThreadSynchronize();
        //shrLog("iteration = %3d, residual = %e\n", k, sqrtf(r1));
        k++;
    }

 cudaFree(d_p);
    cudaFree(d_Ax);
*/ cublasGetVector (N, sizeof(float),X_dev, 1, X, 1);

  cublasFree(vals_dev);
  cublasFree(colind_dev);
  cublasFree(rowptr_dev);
  cublasFree(X_dev);
  cublasFree(B_dev);
  //cublasFree(niter_dev);
  //cublasFree(epsilon_dev);

  cublasShutdown();

  //cout<<"Niter: "<<*niter<<" Epsilon: "<<*epsilon<<endl;
  //for (int k=0; k<N; k++)	cout<<X[k]<<" ";
  //cout<<endl;
}


void cgrad_seq (int N, int nnz, float* vals, int* colind, int* rowptr, float* X, float* B, int* niter, float* epsilon){

 sicl_gscsrcg_seq( N, vals, colind, rowptr, X, B,P_NONE,niter,epsilon);
}
#include<sys/time.h>


void poissonsolve(Image* dest, Image* patch, Image& div, int* pos, int N, int dx, int dy)
{
    int count=0, index=0;
    int w = patch->width();
    int h = patch->height();

    vector<int> rowptr(N+1);
    vector<int>  colind(5*N);
    vector<float> vals(5*N);
    vector<float> X(N);
    vector<float> b(N);

    for (int y=0; y<h; y++)
        for (int x=0; x<w; x++)
            if (pos[x+y*w]>-1)
            {
                b[count]=0.;
                rowptr[count] = index;

                if (y>0 && pos[x+(y-1)*w]>-1)
                {
                    int colIndex = pos[x+(y-1)*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the top boundary
                {
                    b[count] -= (float) (dest->getPixelXY(x+dx,y+dy-1)>BG) ? dest->getPixelXY(x+dx,y+dy-1) : patch->getPixelXY(x,y-1);
                }

                if (x>0 && pos[(x-1)+y*w]>-1)
                {
                    int colIndex = pos[(x-1)+y*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the boundary
                {
                    b[count] -= (float)  (dest->getPixelXY(x+dx-1,y+dy)>BG) ? dest->getPixelXY(x+dx-1,y+dy) : patch->getPixelXY(x-1,y);
                }

                vals[index] = -4.0f;
                colind[index] = pos[x+y*w];
                index++;

                if (y<h-1 && pos[x+(y+1)*w]>-1)
                {
                    int colIndex = pos[x+(y+1)*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the boundary
                {
                    b[count] -= (float) (dest->getPixelXY(x+dx,y+dy+1)>BG) ? dest->getPixelXY(x+dx,y+dy+1) : patch->getPixelXY(x,y+1);
                }

                if (x<w-1 && pos[(x+1)+y*w]>-1)
                {
                    int colIndex = pos[(x+1)+y*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the boundary
                {
                    b[count] -= (float)  (dest->getPixelXY(x+dx+1,y+dy)>BG) ? dest->getPixelXY(x+dx+1,y+dy) : patch->getPixelXY(x+1,y);
                }



                b[count] += div(x,y);
                count++;

            }
    rowptr[count] = index;

    int niter = 300;
    float epsilon = 1e-5f;
     // clock_t tstart, stop;  timeval start, end;  long mtime, seconds, useconds;  gettimeofday(&start, NULL);
	//tstart = clock();
	//if (w>100)
	//	cgrad( N, index, &vals[0], &colind[0],&rowptr[0],&X[0],&b[0],&niter,&epsilon);
    	//else
    		cgrad_seq( N, index, &vals[0], &colind[0],&rowptr[0],&X[0],&b[0],&niter,&epsilon);
        //stop = clock();
	//gettimeofday(&end, NULL);  seconds  = end.tv_sec  - start.tv_sec;  useconds = end.tv_usec - start.tv_usec;  mtime = ((seconds) * 1000 + useconds/1000.0) + 0.5;

    //printf("%d %d: %ld milliseconds\n",count,niter, mtime);  //cerr<<(*patch).width()<<" "<<(float)(stop-tstart)/(float)(CLOCKS_PER_SEC)<<endl;
    //exit(0);
    count = 0;
    for (int y=0; y<h; y++)
        for (int x=0; x<w; x++)
            if (pos[x+y*w]>-1)
            {
                (*patch)(x,y) =  X[count];
                if ((*patch)(x,y)<=BG) (*patch)(x,y)=0.01;
                count++;
            }

}


void poissonsolve_cpu(Image* dest, Image* patch, Image& div, int* pos, int N, int dx, int dy)
{
    int count=0, index=0;
    int w = patch->width();
    int h = patch->height();

    vector<int> rowptr(N+1);
    vector<int>  colind(5*N);
    vector<float> vals(5*N);
    vector<float> X(N);
    vector<float> b(N);

    for (int y=0; y<h; y++)
        for (int x=0; x<w; x++)
            if (pos[x+y*w]>-1)
            {
                b[count]=0.;
                rowptr[count] = index;

                if (y>0 && pos[x+(y-1)*w]>-1)
                {
                    int colIndex = pos[x+(y-1)*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the top boundary
                {
                    b[count] -= (float) (dest->getPixelXY(x+dx,y+dy-1)>BG) ? dest->getPixelXY(x+dx,y+dy-1) : patch->getPixelXY(x,y-1);
                }

                if (x>0 && pos[(x-1)+y*w]>-1)
                {
                    int colIndex = pos[(x-1)+y*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the boundary
                {
                    b[count] -= (float)  (dest->getPixelXY(x+dx-1,y+dy)>BG) ? dest->getPixelXY(x+dx-1,y+dy) : patch->getPixelXY(x-1,y);
                }

                vals[index] = -4.0f;
                colind[index] = pos[x+y*w];
                index++;

                if (y<h-1 && pos[x+(y+1)*w]>-1)
                {
                    int colIndex = pos[x+(y+1)*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the boundary
                {
                    b[count] -= (float) (dest->getPixelXY(x+dx,y+dy+1)>BG) ? dest->getPixelXY(x+dx,y+dy+1) : patch->getPixelXY(x,y+1);
                }

                if (x<w-1 && pos[(x+1)+y*w]>-1)
                {
                    int colIndex = pos[(x+1)+y*w];
                    vals[index] = 1.0f;
                    colind[index] = colIndex;
                    index++;
                }
                else  // at the boundary
                {
                    b[count] -= (float)  (dest->getPixelXY(x+dx+1,y+dy)>BG) ? dest->getPixelXY(x+dx+1,y+dy) : patch->getPixelXY(x+1,y);
                }



                b[count] += div(x,y);
                count++;

            }
    rowptr[count] = index;

    int niter = 300;
    float epsilon = 1e-5f;

	cgrad_seq( N, index, &vals[0], &colind[0],&rowptr[0],&X[0],&b[0],&niter,&epsilon);

    count = 0;
    for (int y=0; y<h; y++)
        for (int x=0; x<w; x++)
            if (pos[x+y*w]>-1)
            {
                (*patch)(x,y) =  X[count];
                if ((*patch)(x,y)<=BG) (*patch)(x,y)=0.01;
                count++;
            }

}
/*
void poissonsolve(Image* dest, Gradient& grad, float boundary)
{
    int x,y,count=0;
    int w = dest->width();
    int h = dest->height();

    uint N = 0;
    int *pos = new int [w*h];
    for (int k=0; k<w*h; k++)  pos[k] = -1;

    for (y=1; y<h-1; y++)
            for (x=1; x<w-1; x++)
        {
            //if ( (*dest)(x,y) > BG )
            {
                pos[x+y*w] = N;
                N++;
            }
            //else pos[x+y*w] = -1;
        }

    LinearSolver S;
    S.Init(N);
    int dx=0; int dy=0;

    Image div = get_divergent(grad);
    div.savePGM("/tmp/res_div.pgm",10);

    for (int y=0; y<h; y++)
            for (int x=0; x<w; x++)
                if (pos[x+y*w]>-1)
                {

                    S.b[count]=0.;

                    if (x>0 && pos[(x-1)+y*w]>-1)
                    {
                        int colIndex = pos[(x-1)+y*w];
                        S.PushElement(colIndex,count,-1.);
                    }
                    else  // at the top boundary
                    {
                        S.b[count] += (float)  dest->getPixelXY(x+dx-1,y+dy);
                    }


                    if (y>0 && pos[x+(y-1)*w]>-1)
                    {
                        int colIndex = pos[x+(y-1)*w];
                        S.PushElement(colIndex,count,-1.);
                    }
                    else  // at the top boundary
                    {
                        S.b[count] += (float) (dest->getPixelXY(x+dx,y+dy-1)>BG);
                    }

                    if (x<w-1 && pos[(x+1)+y*w]>-1)
                    {
                        int colIndex = pos[(x+1)+y*w];
                        S.PushElement(colIndex,count,-1.);
                    }
                    else  // at the top boundary
                    {
                        S.b[count] += (float)  (dest->getPixelXY(x+dx+1,y+dy)>BG);
                    }

                    if (y<h-1 && pos[x+(y+1)*w]>-1)
                    {
                        int colIndex = pos[x+(y+1)*w];
                        S.PushElement(colIndex,count,-1.);
                    }
                    else  // at the top boundary
                    {
                        S.b[count] += (float) (dest->getPixelXY(x+dx,y+dy+1)>BG) ;
                    }

                    S.PushElement(count, count,4.);
                    S.b[count] -= div(x,y);
                    count++;

                }


        S.BiCGradSolve(300);

        count = 0;
        for (int y=0; y<h; y++)
            for (int x=0; x<w; x++)
                if (pos[x+y*w]>-1)
                {
                    (*dest)(x,y) =  S.x[count];
                    count++;
                }

}
*/

void poisson(Image* dest, Image* patch, int dx, int dy, int nlevel, float drange)
{

    Image* mask = graphCut(dest,patch,dx,dy,false);    //Tested and severe=false performs the best
    mask->savePGM("/tmp/mask.pgm");
    int w = patch->width();
    int h = patch->height();
    int *pos = new int [w*h];
    uint N = 0;

    for (int k=0; k<w*h; k++)  pos[k] = -1;

    for (int y=0; y<h-0; y++)
        for (int x=0; x<w-0; x++)
        {
            if ( (*mask)(x,y) > BG )
            {
                pos[x+y*w] = N;
                N++;
            }
        }
    if (N > 0)
    {

       // int count = 0;

        //Gradient grad = get_gradient(*patch);
        Gradient grad(Image(patch->width(),patch->height()),Image(patch->width(),patch->height()));


        for (int i=0; i<patch->width(); i++)
            for (int j=0; j<patch->height(); j++)
            {
                if (dest->inBounds(i+dx,j+dy) && (*mask)(i,j)<=vsSOURCE)
                    (*dest)( i+dx,j+dy)=(*patch)(i,j);
            }


        for (int x=0; x<patch->width(); x++) for (int y=0; y<patch->height(); y++)
            {
                float h = dest->getPixelXY(x+dx, y+dy);
                float h1 = dest->getPixelXY(x+dx-1, y+dy);
                float h2 = dest->getPixelXY(x+dx, y+dy-1);
                if (h1>BG) (grad.first)(x,y)= h - h1;
                if (h2>BG) (grad.second)(x,y)= h - h2;
            }

        ///grad.first.savePGM("/tmp/patchgradx.pgm",10);
        ///grad.second.savePGM("/tmp/patchgrady.pgm",10);

        for (int y=0; y<h; y++)
            for (int x=0; x<w; x++)
                if ( (*mask)(x,y) == vsSINK || (*mask)(x,y) == vsSOURCE ) //
                {
                    grad.first(x,y) = 0;
                    grad.second(x,y) = 0;
                }
        ///grad.first.savePGM("/tmp/patchgradxx.pgm",10);
        ///grad.second.savePGM("/tmp/patchgradyy.pgm",10);


        /*for (int y=0; y<h; y++)
             for (int x=0; x<w; x++)
                 if ( (*mask)(x,y) >= vsSINK )
                     (*patch)(x,y)=(*dest)(x+dx,y+dy);
         patch->savePGM("/tmp/patchbef.pgm",dest->maxval);*/

        Image div = get_divergent(grad);

        div.savePGM("/tmp/patchdiv.pgm",10);
        poissonsolve(dest,patch,div, pos,N, dx,dy);
    }
    //else    cout << "Solver::solve: No masked pixels found (mask color is non-grey)\n";

    delete [] pos;

    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
        {
            if (dest->inBounds(i+dx,j+dy))
                (*dest)( i+dx,j+dy) = (*patch)(i,j) ;
        }

    delete mask;
}

void poisson_blend(Image* dest, Image* patch, int dx, int dy, int nlevel, float drange)
{

    Image* mask = graphCut(dest,patch,dx,dy,false);    //Tested and severe=false performs the best
    int w = patch->width();
    int h = patch->height();
    int *pos = new int [w*h];
    uint N = 0;

    for (int k=0; k<w*h; k++)  pos[k] = -1;


    for (int y=0; y<h; y++)
        for (int x=0; x<w; x++)
        {
            if ( (*mask)(x,y) > BG )
            {
                pos[x+y*w] = N;
                N++;
            }
        }

    if (N > 0)
    {
        Gradient grad(Image(w,h),Image(w,h));
        for (int x=0; x<w; x++)
            for (int y=0; y<h; y++)
                if ( (*mask)(x,y) <= vsSOURCE )
                {
                    grad.first(x,y) = patch->getPixelXY(x,y)-patch->getPixelXY(x-1,y);
                    grad.second(x,y) = patch->getPixelXY(x,y)-patch->getPixelXY(x,y-1);
                }
                else
                {
                    float h = dest->getPixelXY(x+dx, y+dy);
                    float h1 = dest->getPixelXY(x+dx-1, y+dy);
                    float h2 = dest->getPixelXY(x+dx, y+dy-1);
                    if (h1>BG) (grad.first)(x,y)= h - h1;
                    if (h2>BG) (grad.second)(x,y)= h - h2;
                }

        Image div = get_divergent(grad);
        poissonsolve(dest,patch,div,pos,N,dx,dy);

    }
    else
        cout << "Solver::solve: No masked pixels found (mask color is non-grey)\n";

    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
        {
            if (dest->inBounds(i+dx,j+dy))
                (*dest)( i+dx,j+dy) = (*patch)(i,j) ;
        }
    delete [] pos;
    delete mask;
}

void shepard(Image* dest, Image* patch, int dx, int dy, int nlevel, float drange)
{
    Image* mask = graphCut(dest,patch,dx,dy);    //Tested and severe=false performs the best

    //mask->savePGM("/tmp/mask.pgm");

    vector<node_t> seam;
    vector<float>   target_val;

    //patch->savePGM("/tmp/patchdev.pgm",dest->maxval);
    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
        {
            if ( (*mask)(i,j) == vsSINK )
            {
                seam.push_back(node_t(i,j));
                target_val.push_back(dest->getPixelXY(i+dx,j+dy)-(*patch)(i,j));
            }
            if ((*mask)(i,j)>=vsSINK)
                (*patch)(i,j) = (*dest).getPixelXY( i+dx,j+dy);
        }


    //patch->savePGM("/tmp/patchdev2.pgm",dest->maxval);
    sinterpolate(*patch,*mask,seam,target_val,drange);
    //patch->savePGM("/tmp/patch.pgm",dest->maxval);

    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
        {
            if (dest->inBounds(i+dx,j+dy))
            {
                (*dest)( i+dx,j+dy) = (*patch)(i,j) ;
            }
        }
    delete mask;
    //cin.get();

}

void wiredef(Image* dest, Image* patch, int dx, int dy, int nlevel, float doff)
{

    int drange = doff;

    Image psrc = *patch;

    int nwidth = psrc.width() + 2*drange;
    int nheight = psrc.height() + 2*drange;

    Image nsrc(nwidth,nheight);
    Image nmask(nwidth,nheight);
    Image ndest(nwidth,nheight);

    vector<cut_node> cut;
    Image mask(psrc.width(),psrc.height());

    // Determine overlapping area
    for (int x=0; x<psrc.width(); x++) for (int y=0; y<psrc.height(); y++)
            if (x+dx<dest->width() && y+dy<dest->height() && (*dest)(x+dx,y+dy)!=0.)
                cut.push_back( cut_node (node_t(x,y),true) );

    if (cut.size()>0)
    {

        for (unsigned int k=0; k<cut.size(); k++)
        {
            node_t p = cut[k].first;

            bool fg=false;
            if ((p.y==0 || p.x==0 || p.y==psrc.height()-1 || p.x==psrc.width()-1))
            {
                int nx;
                int ny;

                nx = p.x;
                ny = p.y-1;
                if ( ny<0 && ny+dy>=0 && (*dest)(dx+nx, dy+ny)!=0. )	fg = true;

                nx = p.x;
                ny = p.y+1;
                if ( ny>=psrc.height() && ny+dy<(*dest).height() && (*dest)(dx+nx, dy+ny)!=0. )	fg = true;

                nx = p.x-1;
                ny = p.y;
                if ( nx<0 && nx+dx>=0 && (*dest)(dx+nx, dy+ny)!=0. )	fg = true;

                nx = p.x+1;
                ny = p.y;
                if ( nx>=psrc.width() && nx+dx<(*dest).width() && (*dest)(dx+nx, dy+ny)!=0. )	fg = true;

            }
            if (fg)  //Coming from sink
            {
                mask(p.x,p.y) = vsSINK;
                //cost+= (psrc(p.x,p.y)-dest.getPixelXY(dx+p.x,dy+p.y))*(psrc(p.x,p.y)-dest.getPixelXY(dx+p.x,dy+p.y));
            }

        }
    }

    vector<node_t> seam,seam2;
    vector<float> seam_tar,seam2_tar;

    for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
        {
            if ( x+dx-drange>=0 &&  x+dx-drange<dest->width() && y+dy-drange>=0 &&  y+dy-drange<dest->height())
                ndest(x,y) = dest->getPixelXY(x+dx-drange,y+dy-drange);
            nsrc(x,y) = psrc.getPixelXY(x-drange,y-drange);
            if ( x-drange>=0 &&  x-drange<mask.width() && y-drange>=0 &&  y-drange<mask.height())
            {
                //nsrc(x,y) = psrc.getPixelXY(x-drange,y-drange);
                if (mask(x-drange,y-drange)!=0)
                {
                    nmask(x,y) = mask(x-drange,y-drange);
                    //for (int h=0; h<nheight; h++) nmask(x,h) = nmask(x,y); //to  comment
                    if (nmask(x,y)!=vsSINK && nmask(x,y)!=vsSOURCE)
                    {
                        if ((y-drange)-1<0) for (int h=0; h<y; h++) nmask(x,h) = nmask(x,y); //to  comment
                        if ((y-drange)+1>=mask.width()) for (int h=y; h<nheight; h++) nmask(x,h) = nmask(x,y); //to  comment
                    }
                }

            }
            else if (nmask(x,y)==0.) nmask(x,y) = vSINK;
        }

    for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
        {
            if (ndest(x,y)==0.)    ndest(x,y) = psrc.getPixelXY(x-drange,y-drange);
        }

    for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
        {
            if (nmask(x,y)==vsSINK)
            {
                if (x-drange==0 || x-drange==mask.width()-1)
                {
                    seam.push_back(node_t(x,y));
                    seam_tar.push_back(1.*ndest(x,y)+0.0*nsrc(x,y));
                }
                else
                {
                    seam2.push_back(node_t(x,y));
                    seam2_tar.push_back(1.*ndest(x,y)+0.0*nsrc(x,y));
                }
            }
        }

    for (int x=0; x<psrc.width(); x++) for (int y=0; y<psrc.height(); y++)
        {
            if (x+dx<dest->width() && y+dy<dest->height())
            {
                if (mask(x,y)<=vsSOURCE)    (*dest)(x+dx,y+dy) = psrc(x,y);
            }
        }

    if (seam.size()>0)
    {

        vector< Image > nsrc_pyr = nsrc.get_pyramid(nlevel);
        vector< Image > ndest_pyr = ndest.get_pyramid(nlevel);
        vector< Image > seam_pyr;// = target.get_pyramid(nlevel);
        vector< Image > seam2_pyr;// = target2.get_pyramid(nlevel);

        for (unsigned int k=0; k<ndest_pyr.size(); k++)
        {
            Image target(seam.size(),1);
            Image target2(seam2.size(),1);
            for(int x=0; x<target.width(); x++)
            {
                target(x) = ndest_pyr[k](seam[x].x,seam[x].y);
            }
            for(int x=0; x<target2.width(); x++)
            {
                target2(x) = ndest_pyr[k](seam2[x].x,seam2[x].y);
            }
            seam_pyr.push_back(target);
            seam2_pyr.push_back(target2);
        }

        for (int k=0; k<nlevel-1; k++)
        {
            for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
                {
                    nsrc_pyr[k](x,y) =  nsrc_pyr[k](x,y) -nsrc_pyr[k+1](x,y);
                    ndest_pyr[k](x,y) = ndest_pyr[k](x,y)-ndest_pyr[k+1](x,y);
                }
        }

        for (int k=nlevel-1; k>=0; k--)
        {

            //cout<<"Deformation step ...\n";

            wire_deform_shepard(ndest_pyr[k],nsrc_pyr[k],nmask,seam,seam_pyr[k],doff);
            wire_deform_shepard(ndest_pyr[k],nsrc_pyr[k],nmask,seam2,seam2_pyr[k],doff);
            if(k>0)
            {

                for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
                    {
                        nsrc_pyr[k-1](x,y) = nsrc_pyr[k](x,y)+nsrc_pyr[k-1](x,y);
                        ndest_pyr[k-1](x,y) = ndest_pyr[k](x,y)+ndest_pyr[k-1](x,y);
                    }
            }
            doff/=2.;

            if (dy>10000)
            {
                Image ntmp(ndest.width(),ndest.height());
                for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
                    {
                        if (nmask(x,y)<=vsSOURCE ) ntmp(x,y)=nsrc_pyr[k](x,y);
                        else ntmp(x,y)=ndest_pyr[k](x,y);
                    }

                Terrain nter;
                nter.loadTerragen("/tmp/res_tmp.ter");
                for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
                        if ( x+dx-drange>=0 &&  x+dx-drange<dest->width() && y+dy-drange>=0 &&  y+dy-drange<dest->height() && (*dest)(x+dx-drange,y+dy-drange)!=0.)
                        {
                            nter(x+dx-drange,y+dy-drange)=ntmp(x,y);
                        }
                nter.saveTerragen("/tmp/wire_tmp.ter");
                cin.get();
            }

        }

        if (dy>10000)   cout<<"over\n";

        for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
            {
                if ( x-drange>=0 &&  x-drange<mask.width() && y-drange>=0 &&  y-drange<mask.height())
                {
                    psrc(x-drange,y-drange) = nsrc_pyr[0](x,y);
                }
                if (nmask(x,y)<=vsSOURCE )
                    ndest_pyr[0](x,y)=nsrc_pyr[0](x,y);
            }

        for (int x=0; x<nsrc.width(); x++) for (int y=0; y<nsrc.height(); y++)
                if ( x+dx-drange>=0 &&  x+dx-drange<dest->width() && y+dy-drange>=0 &&  y+dy-drange<dest->height() && (*dest)(x+dx-drange,y+dy-drange)!=0.)
                {
                    (*dest)(x+dx-drange,y+dy-drange)=ndest_pyr[0](x,y);
                }

    }
}

void patch_merging(Image* dest_f, Image* patch_f, int dx, int dy, int nlevel, float drange)
{
    int w = (*patch_f).width(), h = patch_f->height();

    Image* mask = graphCut(dest_f,patch_f,dx,dy);    //Tested and severe=false performs the best
    //mask->savePGM("/tmp/mask.pgm");

    Gradient pdest_g(Image(w,h),Image(w,h));
    Gradient patch_g = get_gradient(*patch_f);
    vector<node_t> seam;
    vector<float>   xdiff, ydiff;

    vector<seaminfo> seaminf;

     for (int i=0; i<w; i++)
        for (int j=0; j<h; j++){
            if ( (*mask)(i,j) >= vsSINK){
                float h = dest_f->getPixelXY(i+dx, j+dy);
                float h1 = dest_f->getPixelXY(i+dx-1, j+dy);
                float h2 = dest_f->getPixelXY(i+dx, j+dy-1);
                if (h1>BG) (pdest_g.first)(i,j)= h - h1;
                if (h2>BG) (pdest_g.second)(i,j)= h - h2;
            }
        }

    for (int j=0; j<patch_f->height(); j++)
		   for (int i=0; i<patch_f->width(); i++){
            if ( (*mask)(i,j) == vsSINK ){
                //seam.push_back(node_t(i,j));
                //xdiff.push_back(pdest_g.first(i,j)-patch_g.first(i,j));
                //ydiff.push_back(pdest_g.second(i,j)-patch_g.second(i,j));

                seam.push_back(node_t(i,j));
                seaminfo tmp(node_t(i,j), pdest_g.first(i,j)-patch_g.first(i,j), pdest_g.second(i,j)-patch_g.second(i,j) );
		seaminf.push_back(tmp);
            }

            if ( (*mask)(i,j) >= vsSINK ){
                patch_g.first(i,j) = pdest_g.first(i,j);
                patch_g.second(i,j) = pdest_g.second(i,j);
                (*patch_f)(i,j) = dest_f->getPixelXY(i+dx, j+dy);
            }

        }

    //patch_g.first.savePGM("/tmp/patch_gx_baf.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy_baf.pgm",20);
    //pdest_g.first.savePGM("/tmp/patch_gx_bcf.pgm",20);    pdest_g.second.savePGM("/tmp/patch_gy_bcf.pgm",20);

    if (seam.size()>0)
    {

	{
		int bsize = mask->width();
		//patch_g.first.savePGM("/tmp/patch_gx_bef.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy_bef.pgm",20);
		// Shepard Interpolation
		point_t*  points = new point_t[bsize*bsize];
		for (int j=0; j<patch_f->height(); j++)
		   for (int i=0; i<patch_f->width(); i++){
				 point_t tmp(-1e5,-1e5);
				 if ( (*mask)(i,j) < vsSINK )
				 	tmp = point_t(0,0);
				 points[i+j*bsize] = tmp;
			}

		//sinterpolate_cpu(points, &seaminf[0], seaminf.size(), bsize, drange);

		point_t* points_dev;	cudaMalloc( (void**) &points_dev, sizeof(point_t)*bsize*bsize );
		seaminfo* seaminf_dev;	cudaMalloc( (void**) &seaminf_dev, sizeof(seaminfo)*seaminf.size() );

		cudaMemcpy(points_dev, points,  sizeof(point_t)*bsize*bsize, cudaMemcpyHostToDevice );
		cudaMemcpy(seaminf_dev, &seaminf[0],  sizeof(seaminfo)*seaminf.size(), cudaMemcpyHostToDevice );

		dim3 dimGrid( (bsize/TILE_WIDTH)+1, (bsize/TILE_WIDTH)+1);
	   	dim3 dimBlock(TILE_WIDTH,TILE_WIDTH);
		sinterpolate_gpu<<<dimGrid,dimBlock>>>(points_dev, seaminf_dev, seaminf.size(), bsize, drange);
		cudaMemcpy(points, points_dev,  sizeof(point_t)*bsize*bsize, cudaMemcpyDeviceToHost );

		cudaFree(points_dev);
		cudaFree(seaminf_dev);

		for (int j=0; j<patch_f->height(); j++)
		   for (int i=0; i<patch_f->width(); i++)
		    	if ( (*mask)(i,j) < vsSINK ){
		    	patch_g.first(i,j) = patch_g.first(i,j) + points[i+j*bsize].x; //(wsrcx/wtot);
		        patch_g.second(i,j) = patch_g.second(i,j) + points[i+j*bsize].y; //(wsrcy/wtot);
		    }

		delete [] points;
	}

        //patch_g.first.savePGM("/tmp/patch_gx_bef.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy_bef.pgm",20);
        //sinterpolate_g(patch_g,*mask,seam,xdiff,ydiff,drange);
        //patch_g.first.savePGM("/tmp/patch_gx.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy.pgm",20);

        Image div= get_divergent(patch_g);
        //div.savePGM("/tmp/patch_div.pgm",15);

        int *pos = new int [w*h];
        uint N = 0;

        for (int y=0; y<h; y++)
            for (int x=0; x<w; x++)
            {
                pos[x+y*w] = N;
                N++;
            }
        //cin.get();
        //patch_f->savePGM("/tmp/res_cand1.pgm",dest_f->maxval);
        poissonsolve(dest_f,patch_f,div,pos,N,dx,dy);
        //patch_f->savePGM("/tmp/res_cand2.pgm",dest_f->maxval);
        //cin.get();
        delete [] pos;

    }


    for (int i=0; i<patch_f->width(); i++)
        for (int j=0; j<patch_f->height(); j++)
        {
            if (dest_f->inBounds(i+dx,j+dy))
            {
                (*dest_f)( i+dx,j+dy) = (*patch_f)(i,j) ;
            }
        }

    delete mask;

}

void feathering(Image* dest, Image* patch, int dx, int dy, int nlevel, float drange)
{

    Image* mask = graphCut(dest,patch,dx,dy);    //Tested and severe=false performs the best

    vector<node_t> seam;
    vector<float>   src_val, dest_val;
    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
            if ( (*mask)(i,j) == vsSINK )
            {
                seam.push_back(node_t(i,j));
                src_val.push_back((*patch)(i,j));
                dest_val.push_back(dest->getPixelXY(i+dx,j+dy));
            }

    for (int i=0; i<patch->width(); i++)
    {
        for (int j=0; j<patch->height(); j++)
        {
            node_t p(i,j);
            int knear = near2seam(p,seam);
            if (knear==-1)   break;
            float dnear = ndistance(p,seam[knear]);
            if ( dnear<drange && (*mask)(i,j)>BG && (*mask)(i,j)<vsSINK )
            {
                float w = dnear/drange;
                w = (w*w-1)*(w*w-1);
                //(*patch)(i,j) = (1-w)*(*patch)(i,j) + (w)*dest->getPixelXY(i+dx,j+dy);
                //(*patch)(i,j) += w*(dest_val[knear]-src_val[knear]);
            }

        }
    }

    for (int i=0; i<patch->width(); i++)
        for (int j=0; j<patch->height(); j++)
        {
            if (dest->inBounds(i+dx,j+dy))// && (*mask)(i,j)<=vsSOURCE)
                (*dest)( i+dx,j+dy) = (*patch)(i,j) ;
        }

    delete mask;
}


void patch_merging_cpu(Image* dest_f, Image* patch_f, int dx, int dy, int nlevel, float drange)
{
    int w = (*patch_f).width(), h = patch_f->height();

    Image* mask = graphCut(dest_f,patch_f,dx,dy);    //Tested and severe=false performs the best
    //mask->savePGM("/tmp/mask.pgm");

    Gradient pdest_g(Image(w,h),Image(w,h));
    Gradient patch_g = get_gradient(*patch_f);
    vector<node_t> seam;
    vector<float>   xdiff, ydiff;

    vector<seaminfo> seaminf;

     for (int i=0; i<w; i++)
        for (int j=0; j<h; j++){
            if ( (*mask)(i,j) >= vsSINK){
                float h = dest_f->getPixelXY(i+dx, j+dy);
                float h1 = dest_f->getPixelXY(i+dx-1, j+dy);
                float h2 = dest_f->getPixelXY(i+dx, j+dy-1);
                if (h1>BG) (pdest_g.first)(i,j)= h - h1;
                if (h2>BG) (pdest_g.second)(i,j)= h - h2;
            }
        }

    for (int j=0; j<patch_f->height(); j++)
		   for (int i=0; i<patch_f->width(); i++){
            if ( (*mask)(i,j) == vsSINK ){
                //seam.push_back(node_t(i,j));
                //xdiff.push_back(pdest_g.first(i,j)-patch_g.first(i,j));
                //ydiff.push_back(pdest_g.second(i,j)-patch_g.second(i,j));

                seam.push_back(node_t(i,j));
                seaminfo tmp(node_t(i,j), pdest_g.first(i,j)-patch_g.first(i,j), pdest_g.second(i,j)-patch_g.second(i,j) );
		seaminf.push_back(tmp);
            }

            if ( (*mask)(i,j) >= vsSINK ){
                patch_g.first(i,j) = pdest_g.first(i,j);
                patch_g.second(i,j) = pdest_g.second(i,j);
                (*patch_f)(i,j) = dest_f->getPixelXY(i+dx, j+dy);
            }

        }

    //patch_g.first.savePGM("/tmp/patch_gx_baf.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy_baf.pgm",20);
    //pdest_g.first.savePGM("/tmp/patch_gx_bcf.pgm",20);    pdest_g.second.savePGM("/tmp/patch_gy_bcf.pgm",20);

    if (seam.size()>0)
    {

	{
		int bsize = mask->width();
		//patch_g.first.savePGM("/tmp/patch_gx_bef.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy_bef.pgm",20);
		// Shepard Interpolation
		point_t*  points = new point_t[bsize*bsize];
		for (int j=0; j<patch_f->height(); j++)
		   for (int i=0; i<patch_f->width(); i++){
				 point_t tmp(-1e5,-1e5);
				 if ( (*mask)(i,j) < vsSINK )
				 	tmp = point_t(0,0);
				 points[i+j*bsize] = tmp;
			}

		//sinterpolate_cpu(points, &seaminf[0], seaminf.size(), bsize, drange);

		dim3 dimGrid( (bsize/TILE_WIDTH)+1, (bsize/TILE_WIDTH)+1);
	   	dim3 dimBlock(TILE_WIDTH,TILE_WIDTH);
		sinterpolate_cpu(points, &seaminf[0], seaminf.size(), bsize, drange);

		for (int j=0; j<patch_f->height(); j++)
		   for (int i=0; i<patch_f->width(); i++)
		    	if ( (*mask)(i,j) < vsSINK ){
		    	patch_g.first(i,j) = patch_g.first(i,j) + points[i+j*bsize].x; //(wsrcx/wtot);
		        patch_g.second(i,j) = patch_g.second(i,j) + points[i+j*bsize].y; //(wsrcy/wtot);
		    }

		delete [] points;
	}

        //patch_g.first.savePGM("/tmp/patch_gx_bef.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy_bef.pgm",20);
        //sinterpolate_g(patch_g,*mask,seam,xdiff,ydiff,drange);
        //patch_g.first.savePGM("/tmp/patch_gx.pgm",20);    patch_g.second.savePGM("/tmp/patch_gy.pgm",20);

        Image div= get_divergent(patch_g);
        //div.savePGM("/tmp/patch_div.pgm",15);

        int *pos = new int [w*h];
        uint N = 0;

        for (int y=0; y<h; y++)
            for (int x=0; x<w; x++)
            {
                pos[x+y*w] = N;
                N++;
            }
        //cin.get();
        //patch_f->savePGM("/tmp/res_cand1.pgm",dest_f->maxval);
        poissonsolve_cpu(dest_f,patch_f,div,pos,N,dx,dy);
        //patch_f->savePGM("/tmp/res_cand2.pgm",dest_f->maxval);
        //cin.get();
        delete [] pos;

    }


    for (int i=0; i<patch_f->width(); i++)
        for (int j=0; j<patch_f->height(); j++)
        {
            if (dest_f->inBounds(i+dx,j+dy))
            {
                (*dest_f)( i+dx,j+dy) = (*patch_f)(i,j) ;
            }
        }

    delete mask;

}