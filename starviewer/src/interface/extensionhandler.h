/***************************************************************************
 *   Copyright (C) 2005 by Grup de Gr�fics de Girona                       *
 *   http://iiia.udg.es/GGG/index.html?langu=uk                            *
 *                                                                         *
 *   Universitat de Girona                                                 *
 ***************************************************************************/
#ifndef UDGEXTENSIONHANDLER_H
#define UDGEXTENSIONHANDLER_H

#include <QObject>
#include <QString>
#include "identifier.h"
#include "patient.h"
#include "studyvolum.h"

namespace udg {

// Fordward Declarations
class VolumeRepository;
class Input;
class Output;
class QApplicationMainWindow;
class Volume;
class ExtensionFactory;

class QMPRExtensionCreator;
class QMPR3DExtensionCreator;
class QMPR3D2DExtensionCreator;
class QDefaultViewerExtensionCreator;

// Espai reservat pels fwd decl de les mini-apps
class AppImportFile;

// Fi de l'Espai reservat pels fwd decl de les mini-apps
class QueryScreen;
/**
Gestor de mini-aplicacions i serveis de l'aplicaci� principal

@author Grup de Gr�fics de Girona  ( GGG )

\TODO: temporalment seguirem el patr� 1 aplicaci�/servei : 1 m�tode p�blic

*/
class ExtensionHandler : public QObject{
Q_OBJECT
public:
    ExtensionHandler( QApplicationMainWindow *mainApp , QObject *parent = 0, const char *name = 0);

    ~ExtensionHandler();

    /// Presenta les mini-apps a la aplicaci� principal, posant-les a l'abast. ( el m�tode es podria dir tamb� spreadExtensions o algo aix�)
    void introduceApplications();
    
    /// Obre un volum a partir d'un fitxer \TODO ara es fa tot a saco aqu� dins per� potser seria millor que ho fe suna clase externa especialitzada
    bool open( QString fileName );

    /// \TODO Aix� �s un "apanyo"
    void setVolumeID( Identifier id ){ m_volumeID = id; }
    
public slots:
    /// rep la petici� d'un servei/mini-aplicaci� i fa el que calgui
    void request( int who );
    void request( const QString &who );

    /// aplicaci� que s'executa per defecte quan carreguem un volum al repositori
    void onVolumeLoaded( Identifier id );

    /// [apanyo] es crida quan es demana un studi descarregat, es veu la pimera serie
    void viewStudy( StudyVolum study );

    /// [apanyo] Slot que afegeix al 2n visor una s�rie escollida per comparar-> �s un m�tode moooolt temporal. 
    void viewStudyToCompare( StudyVolum study );

private:
    /// Punter a l'aplicaci� principal
    QApplicationMainWindow *m_mainApp;
    
    /// Factoria d'extensions
    ExtensionFactory *m_extensionFactory;
    
    /// Creadors d'extensions
    QMPRExtensionCreator *m_qMPRExtensionCreator;
    QMPR3DExtensionCreator *m_qMPR3DExtensionCreator;
    QMPR3D2DExtensionCreator *m_qMPR3D2DExtensionCreator;
    QDefaultViewerExtensionCreator *m_qDefaultViewerExtensionCreator;

    /// Entitat pacient que es controlar� des d'aqu�
    Patient m_patient;
    
    /// S'encarrega de fer el registre de totes les extensions amb el factory
    void registerExtensions();

    /// Crea les connexions de signals i slots
    void createConnections();
    
    // :::::::::::::::::::::::::::::::::::::::::
    // Recursos
    // :::::::::::::::::::::::::::::::::::::::::

    /// L'id del volum amb el que estem treballant
    Identifier m_volumeID;    
    /// El repository de volums
    udg::VolumeRepository* m_volumeRepository;
    /// acc�s a l'entrada de dades -> aix� hauria de formar part d'una mini-app, per tant �s temporal
    Input *m_inputReader;
    /// acc�s a la sortida/escriptura de dades -> aix� hauria de formar part d'una mini-app, per tant �s temporal
    Output *m_outputWriter;
    
    // :::::::::::::::::::::::::::::::::::::::::
    // Mini Aplicacions
    // Aqu� es declararan totes les mini-aplicacions que es faran servir
    // :::::::::::::::::::::::::::::::::::::::::
    
    /// Importar models del sistema de fitxers al repositori de volums
    AppImportFile *m_importFileApp;
    
    /// La pantalla d'acc�s al pacs
    QueryScreen *m_queryScreen;

private slots:

    /// Slot que es crida quan hem canviat d'una extensi� a una altre
    void extensionChanged( int index );

    /// [temporal] Obre una s�rie per comparar en el visor per defecte
    void openSerieToCompare();

signals:
    /// Emet un senyal amb el segon volum per comparar
    void secondInput( Volume* );
};

};  //  end  namespace udg 

#endif
